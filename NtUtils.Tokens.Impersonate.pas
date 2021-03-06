unit NtUtils.Tokens.Impersonate;

interface

{ NOTE: All functions here support pseudo-handles on input on all OS versions }

uses
  NtUtils.Exceptions, NtUtils.Objects;

// Save current impersonation token before operations that can alter it
function NtxBackupImpersonation(hThread: THandle): IHandle;
procedure NtxRestoreImpersonation(hThread: THandle; hxToken: IHandle);

// Set thread token
function NtxSetThreadToken(hThread: THandle; hToken: THandle): TNtxStatus;
function NtxSetThreadTokenById(TID: NativeUInt; hToken: THandle): TNtxStatus;

// Set thread token and make sure it was not duplicated to Identification level
function NtxSafeSetThreadToken(hThread: THandle; hToken: THandle;
  SkipInputLevelCheck: Boolean = False): TNtxStatus;
function NtxSafeSetThreadTokenById(TID: NativeUInt; hToken: THandle;
  SkipInputLevelCheck: Boolean = False): TNtxStatus;

// Impersonate the token of any type on the current thread
function NtxImpersonateAnyToken(hToken: THandle): TNtxStatus;

// Assign primary token to a process
function NtxAssignPrimaryToken(hProcess: THandle; hToken: THandle): TNtxStatus;
function NtxAssignPrimaryTokenById(PID: NativeUInt; hToken: THandle): TNtxStatus;

implementation

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, Ntapi.ntseapi,
  NtUtils.Tokens, NtUtils.Processes, NtUtils.Threads, NtUtils.Tokens.Query;

{ Impersonation }

function NtxBackupImpersonation(hThread: THandle): IHandle;
var
  Status: NTSTATUS;
begin
  // Open the thread's token
  Status := NtxOpenThreadToken(Result, hThread, TOKEN_IMPERSONATE).Status;

  if Status = STATUS_NO_TOKEN then
    Result := nil
  else if not NT_SUCCESS(Status) then
  begin
    // Most likely the token is here, but we can't access it. Although we can
    // make a copy via direct impersonation, I am not sure we should do it.
    // Currently, just clear the token as most of Winapi functions do in this
    // situation
    Result := nil;

    if hThread = NtCurrentThread then
      ENtError.Report(Status, 'NtxBackupImpersonation');
  end;
end;

procedure NtxRestoreImpersonation(hThread: THandle; hxToken: IHandle);
begin
  // Try to establish the previous token
  if not Assigned(hxToken) or not NtxSetThreadToken(hThread,
    hxToken.Handle).IsSuccess then
    NtxSetThreadToken(hThread, 0);
end;

function NtxSetThreadToken(hThread: THandle; hToken: THandle): TNtxStatus;
var
  hxToken: IHandle;
begin
  // Handle pseudo-handles as well
  Result := NtxExpandPseudoToken(hxToken, hToken, TOKEN_IMPERSONATE);

  if Result.IsSuccess then
    Result := NtxThread.SetInfo(hThread, ThreadImpersonationToken,
      hxToken.Handle);

  // TODO: what about inconsistency with NtCurrentTeb.IsImpersonating ?
end;

function NtxSetThreadTokenById(TID: NativeUInt; hToken: THandle): TNtxStatus;
var
  hxThread: IHandle;
begin
  Result := NtxOpenThread(hxThread, TID, THREAD_SET_THREAD_TOKEN);

  if Result.IsSuccess then
    Result := NtxSetThreadToken(hxThread.Handle, hToken);
end;

{ Some notes about safe impersonation...

   Usually, the system establishes the exact token we passed to the system call
   as an impersonation token for the target thread. However, in some cases it
   duplicates the token or adjusts it a bit.

 * Anonymous up to identification-level tokens do not require any special
   treatment - you can impersonate any of them without limitations.

 As for impersonation- and delegation-level tokens:

 * If the target process does not have SeImpersonatePrivilege, some security
   contexts can't be impersonated by its threads. The system duplicates such
   tokens to identification level which fails all further access checks for
   the target thread. Unfortunately, the result of NtSetInformationThread does
   not provide any information whether it happened. The goal is to detect and
   avoid such situations since we should consider such impersonations as failed.

 * Also, if the trust level of the target process is lower than the trust level
   specified in the token, the system duplicates the token removing the trust
   label; as for the rest, the impersonations succeeds. This scenario does not
   allow us to determine whether the impersonation was successful by simply
   comparing the source and the actually set tokens. Duplication does not
   necessarily means failed impersonation.

   NtxSafeSetThreadToken sets the token, queries what was actually set, and
   checks the impersonation level. Anything but success causes the routine to
   undo its work.

 Note:

   The security context of the target thread is not guaranteed to return to its
   previous state. It might happen if the target thread is impersonating a token
   that the caller can't open. In this case after the failed call the target
   thread will have no token.

   To address this issue the caller can make a copy of the target thread's
   token by using NtImpersonateThread. See implementation of
   NtxDuplicateEffectiveToken for more details.

 Other possible implementations:

 * Since NtImpersonateThread fails with BAD_IMPERSONATION_LEVEL when we request
   Impersonation-level token while the thread's token is Identification or less.
   We can use this behaviour to determine which level the target token is.
}

function NtxSafeSetThreadToken(hThread: THandle; hToken: THandle;
  SkipInputLevelCheck: Boolean): TNtxStatus;
var
  hxBackupToken, hxActuallySetToken, hxToken: IHandle;
  Stats: TTokenStatistics;
begin
  // No need to use safe impersonation to revoke tokens
  if hToken = 0 then
    Exit(NtxSetThreadToken(hThread, hToken));

  // Make sure to handle pseudo-tokens as well
  Result := NtxExpandPseudoToken(hxToken, hToken, TOKEN_IMPERSONATE or
    TOKEN_QUERY);

  if not Result.IsSuccess then
    Exit;

  if not SkipInputLevelCheck then
  begin
    // Determine the impersonation level of the token
    Result := NtxToken.Query(hxToken.Handle, TokenStatistics, Stats);

    if not Result.IsSuccess then
      Exit;

    // Anonymous up to Identification do not require any special treatment
    if (Stats.TokenType <> TokenImpersonation) or (Stats.ImpersonationLevel <
      SecurityImpersonation) then
      Exit(NtxSetThreadToken(hThread, hxToken.Handle));
  end;

  // Backup old state
  hxBackupToken := NtxBackupImpersonation(hThread);

  // Set the token
  Result := NtxSetThreadToken(hThread, hxToken.Handle);

  if not Result.IsSuccess then
    Exit;

  // Read it back for further checks
  Result := NtxOpenThreadToken(hxActuallySetToken, hThread, TOKEN_QUERY);

  // Determine the actual impersonation level
  if Result.IsSuccess then
  begin
    Result := NtxToken.Query(hxActuallySetToken.Handle, TokenStatistics, Stats);

    if Result.IsSuccess and (Stats.ImpersonationLevel < SecurityImpersonation)
      then
    begin
      // Fail. SeImpersonatePrivilege on the target process can help
      Result.Location := 'NtxSafeSetThreadToken';
      Result.LastCall.ExpectedPrivilege := SE_IMPERSONATE_PRIVILEGE;
      Result.Status := STATUS_PRIVILEGE_NOT_HELD;
    end;
  end;

  // Reset on failure
  if not Result.IsSuccess then
    NtxRestoreImpersonation(hThread, hxBackupToken);
end;

function NtxSafeSetThreadTokenById(TID: NativeUInt; hToken: THandle;
  SkipInputLevelCheck: Boolean): TNtxStatus;
var
  hxThread: IHandle;
begin
  Result := NtxOpenThread(hxThread, TID, THREAD_QUERY_LIMITED_INFORMATION or
    THREAD_SET_THREAD_TOKEN);

  if Result.IsSuccess then
    Result := NtxSafeSetThreadToken(hxThread.Handle, hToken, SkipInputLevelCheck);
end;

function NtxImpersonateAnyToken(hToken: THandle): TNtxStatus;
var
  hxToken, hxImpToken: IHandle;
begin
  Result := NtxExpandPseudoToken(hxToken, hToken, TOKEN_IMPERSONATE);

  if not Result.IsSuccess then
    Exit;

  // Try to impersonate (in case it is an impersonation-type token)
  Result := NtxSetThreadToken(NtCurrentThread, hxToken.Handle);

  if Result.Matches(STATUS_BAD_TOKEN_TYPE, 'NtSetInformationThread') then
  begin
    // Nope, it is a primary token, duplicate it
    Result := NtxDuplicateToken(hxImpToken, hToken, TOKEN_IMPERSONATE,
      TokenImpersonation, SecurityImpersonation);

    // Impersonate, second attempt
    if Result.IsSuccess then
      Result := NtxSetThreadToken(NtCurrentThread, hxImpToken.Handle);
  end;
end;

function NtxAssignPrimaryToken(hProcess: THandle;
  hToken: THandle): TNtxStatus;
var
  hxToken: IHandle;
  AccessToken: TProcessAccessToken;
begin
  // Manage pseudo-tokens
  Result := NtxExpandPseudoToken(hxToken, hToken, TOKEN_ASSIGN_PRIMARY);

  if Result.IsSuccess then
  begin
    AccessToken.Thread := 0; // Looks like the call ignores it
    AccessToken.Token := hxToken.Handle;

    Result := NtxProcess.SetInfo(hProcess, ProcessAccessToken, AccessToken);
  end;
end;

function NtxAssignPrimaryTokenById(PID: NativeUInt;
  hToken: THandle): TNtxStatus;
var
  hxProcess: IHandle;
begin
  Result := NtxOpenProcess(hxProcess, PID, PROCESS_SET_INFORMATION);

  if not Result.IsSuccess then
    Exit;

  Result := NtxAssignPrimaryToken(hxProcess.Handle, hToken);
end;

end.
