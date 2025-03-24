const std = @import("std");

const pam = @cImport({
    @cInclude("security/pam_appl.h");
});

pub const MAX_RESP_SIZE = pam.PAM_MAX_RESP_SIZE;

pub const ReturnCode = enum(u8) {
    Success = pam.PAM_SUCCESS,
    OpenErr = pam.PAM_OPEN_ERR,
    SymbolErr = pam.PAM_SYMBOL_ERR,
    ServiceErr = pam.PAM_SERVICE_ERR,
    SystemErr = pam.PAM_SYSTEM_ERR,
    BufErr = pam.PAM_BUF_ERR,
    PermDenied = pam.PAM_PERM_DENIED,
    AuthErr = pam.PAM_AUTH_ERR,
    CredInsufficient = pam.PAM_CRED_INSUFFICIENT,
    AuthinfoUnavail = pam.PAM_AUTHINFO_UNAVAIL,
    UserUnknown = pam.PAM_USER_UNKNOWN,
    Maxtries = pam.PAM_MAXTRIES,
    NewAuthtok_reqd = pam.PAM_NEW_AUTHTOK_REQD,
    AcctExpired = pam.PAM_ACCT_EXPIRED,
    SessionErr = pam.PAM_SESSION_ERR,
    CredUnavail = pam.PAM_CRED_UNAVAIL,
    CredExpired = pam.PAM_CRED_EXPIRED,
    CredErr = pam.PAM_CRED_ERR,
    NoModuleData = pam.PAM_NO_MODULE_DATA,
    ConvErr = pam.PAM_CONV_ERR,
    AuthtokErr = pam.PAM_AUTHTOK_ERR,
    AuthtokRecoveryErr = pam.PAM_AUTHTOK_RECOVERY_ERR,
    AuthtokLockBusy = pam.PAM_AUTHTOK_LOCK_BUSY,
    AuthtokDisableAging = pam.PAM_AUTHTOK_DISABLE_AGING,
    TryAgain = pam.PAM_TRY_AGAIN,
    Ignore = pam.PAM_IGNORE,
    Abort = pam.PAM_ABORT,
    AuthtokExpired = pam.PAM_AUTHTOK_EXPIRED,
    ModuleUnknown = pam.PAM_MODULE_UNKNOWN,
    BadItem = pam.PAM_BAD_ITEM,
    ConvAgain = pam.PAM_CONV_AGAIN,
    Incomplete = pam.PAM_INCOMPLETE,
};

pub const MessageStyle = enum(u8) {
    PromptEchoOff = pam.PAM_PROMPT_ECHO_OFF,
    PromptEchoOn = pam.PAM_PROMPT_ECHO_ON,
    ErrorMsg = pam.PAM_ERROR_MSG,
    TextInfo = pam.PAM_TEXT_INFO,
};

pub const Conversation = pam.struct_pam_conv;
pub const Message = pam.struct_pam_message;
pub const Response = pam.struct_pam_response;

pub const Handle = opaque {
    pub fn start(
        service_name: [*c]const u8,
        user: [*c]const u8,
        pam_conversation: [*c]const pam.struct_pam_conv,
    ) !*Handle {
        var handle: ?*pam.pam_handle = null;
        switch (pamReturn(pam.pam_start(service_name, user, pam_conversation, &handle))) {
            .Success => return @ptrCast(handle),
            .Abort => return error.Abort,
            .BufErr => return error.Buffer,
            .SystemErr => return error.System,
            else => |err| return unexpectedReturnValue(err),
        }
    }

    pub fn authenticate(pamh: *Handle, flags: c_int) ReturnCode {
        return @enumFromInt(pam.pam_authenticate(@ptrCast(pamh), flags));
    }

    pub fn end(pamh: *Handle, pam_status: ReturnCode) void {
        switch (pamReturn(pam.pam_end(@ptrCast(pamh), @intFromEnum(pam_status)))) {
            .Success => return,
            .SystemErr => std.log.warn("System error on pam_end. Was handle null?", .{}),
            else => std.log.warn("Unexpected return code from pam_end", .{}),
        }
    }

    pub fn strerror(pamh: *Handle, pam_status: ReturnCode) [*c]const u8 {
        return pam.pam_strerror(@ptrCast(pamh), @intFromEnum(pam_status));
    }
};

pub const UnexpectedError = error{
    Unexpected,
};

fn pamReturn(rc: c_int) ReturnCode {
    return @enumFromInt(rc);
}

fn unexpectedReturnValue(err: ReturnCode) UnexpectedError {
    std.debug.print("unexpected errno: {d}\n", .{@intFromEnum(err)});
    std.debug.dumpCurrentStackTrace(null);
    return error.Unexpected;
}
