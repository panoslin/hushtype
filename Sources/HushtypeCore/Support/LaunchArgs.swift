/// Launch arguments the app reacts to. Only QA builds (`QA=1 Scripts/build_app.sh`, -DHUSHTYPE_QA) read the
/// command line: in the release app, test hooks like `--qa-key-file` or `--test-audio` must not exist.
public enum LaunchArgs {
    #if HUSHTYPE_QA
    public static let all = CommandLine.arguments
    #else
    public static let all = Array(CommandLine.arguments.prefix(1))
    #endif
}
