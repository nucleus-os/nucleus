import Foundation
import SwiftBasicFormat
import SwiftSyntax
import SwiftSyntaxBuilder

/// Deterministic Swift source assembly for generated protocol modules.
///
/// Emitters add syntax declarations rather than concatenating source text. The
/// only strings accepted here are identifier names already validated by the
/// generator's naming layer.
struct SwiftSourceFileBuilder {
    private var declarations: [DeclSyntax] = []

    mutating func addImport(_ module: String, public isPublic: Bool = false) {
        let modifiers: DeclModifierListSyntax = isPublic
            ? [DeclModifierSyntax(name: .keyword(.public))]
            : []
        let declaration = ImportDeclSyntax(
            modifiers: modifiers,
            path: [
                ImportPathComponentSyntax(name: .identifier(module)),
            ])
        declarations.append(DeclSyntax(declaration))
    }

    mutating func add(_ declaration: DeclSyntax) {
        declarations.append(declaration)
    }

    mutating func add<S: Sequence>(contentsOf newDeclarations: S)
    where S.Element == DeclSyntax {
        declarations.append(contentsOf: newDeclarations)
    }

    func rendered(header: [String]) -> String {
        let statements = CodeBlockItemListSyntax(
            declarations.map {
                CodeBlockItemSyntax(item: .decl($0))
            })
        var source = SourceFileSyntax(
            statements: statements,
            endOfFileToken: .endOfFileToken())
        source.leadingTrivia = Trivia(
            pieces: header.flatMap {
                [.lineComment("// \($0)"), .newlines(1)]
            } + [.newlines(1)])
        return source.formatted(using: BasicFormat()).description
    }

    func write(to path: String, header: [String]) throws {
        try rendered(header: header).write(
            toFile: path, atomically: true, encoding: .utf8)
    }
}
