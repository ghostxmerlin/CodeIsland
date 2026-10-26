/// aism ⇄ the Meyrin input method over local CFMessagePorts (no distributed notifications: dictated text stays
/// private). One definition for both sides (the app and the input method bundle).
///   aism → IME  `imePort`  msgid `commit`    = UTF-8 text; reply `ok` or `inactive`
///   IME → aism  `appPort`  msgid `activated` = the client's bundle id
public enum MeilingIPC {
    public static let imePort = "com.aism.meiling.ime", appPort = "com.aism.meiling.app"
    public static let commit: Int32 = 1, activated: Int32 = 2
    public static let ok = "ok", inactive = "inactive"
}
