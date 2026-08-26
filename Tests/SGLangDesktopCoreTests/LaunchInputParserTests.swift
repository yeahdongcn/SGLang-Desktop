import Testing

@testable import SGLangDesktopCore

@Test func parsesQuotedArgumentsWithoutShellExpansion() throws {
    let arguments = try LaunchInputParser.arguments(
        from: "--chat-template 'my template.jinja' --label=hello\\ world '$HOME'"
    )
    #expect(
        arguments == [
            "--chat-template", "my template.jinja", "--label=hello world", "$HOME",
        ]
    )
}

@Test func parsesEnvironmentLines() throws {
    let environment = try LaunchInputParser.environment(
        from: "# optional values\nSGLANG_FOO=one two\nEMPTY=\n"
    )
    #expect(environment == ["SGLANG_FOO": "one two", "EMPTY": ""])
}

@Test func rejectsMalformedAdvancedInput() {
    #expect(throws: LaunchInputError.self) {
        try LaunchInputParser.arguments(from: "--flag 'unterminated")
    }
    #expect(throws: LaunchInputError.self) {
        try LaunchInputParser.environment(from: "NOT AN ASSIGNMENT")
    }
    #expect(throws: LaunchInputError.self) {
        try LaunchInputParser.environment(from: "PYTHONPATH=/tmp/injected")
    }
    #expect(throws: LaunchInputError.self) {
        try LaunchInputParser.environment(from: "HF_TOKEN=secret")
    }
}
