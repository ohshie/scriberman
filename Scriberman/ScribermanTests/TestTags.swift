import Testing

extension Tag {
    /// A test that reads a source file through `#filePath` and asserts on its text. It protects a
    /// code convention, not runtime behaviour, so reports can list it apart from behaviour tests.
    @Tag static var sourceLint: Self
}
