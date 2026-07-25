import ColliderPlatformC
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum LoadedLibrary {
    public static func path(
        containingSymbol symbol: String
    ) throws -> String {
        guard !symbol.isEmpty,
            symbol.allSatisfy({
                $0.isASCII
                    && ($0.isLetter || $0.isNumber || $0 == "_")
            })
        else {
            throw LoadedLibraryFailure.invalidSymbol(symbol)
        }
        guard let loadedPath = symbol.withCString({
            unsafe collider_copy_loaded_library_path($0)
        }) else {
            throw LoadedLibraryFailure.notFound(
                symbol: symbol,
                code: errno)
        }
        defer { unsafe free(loadedPath) }
        return unsafe String(cString: loadedPath)
    }
}

public enum LoadedLibraryFailure:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case invalidSymbol(String)
    case notFound(symbol: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidSymbol(let symbol):
            "invalid dynamic-library symbol: \(symbol)"
        case .notFound(let symbol, let code):
            "cannot resolve the loaded library containing \(symbol) "
                + "(errno \(code))"
        }
    }
}
