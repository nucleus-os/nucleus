#!/usr/bin/env python3
"""Functional validation for an assembled Swift toolchain."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import select
import shutil
import subprocess
import sys
import threading
import time
from typing import Any


class ValidationFailure(RuntimeError):
    pass


def write(path: pathlib.Path, contents: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(contents, bytes):
        path.write_bytes(contents)
    else:
        path.write_text(contents, encoding="utf-8")


class LSPClient:
    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        if process.stdin is None or process.stdout is None or process.stderr is None:
            raise ValidationFailure("sourcekit-lsp pipes were not created")
        self.process = process
        self.stdin = process.stdin
        self.stdout = process.stdout
        self.buffer = bytearray()
        self.diagnostics: dict[str, list[dict[str, Any]]] = {}
        self.stderr_lines: list[str] = []
        self.stderr_thread = threading.Thread(
            target=self._drain_stderr, args=(process.stderr,), daemon=True
        )
        self.stderr_thread.start()

    def _drain_stderr(self, stderr: Any) -> None:
        for line in iter(stderr.readline, b""):
            self.stderr_lines.append(line.decode("utf-8", errors="replace").rstrip())

    def send(self, message: dict[str, Any]) -> None:
        payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
        self.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii"))
        self.stdin.write(payload)
        self.stdin.flush()

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, identifier: int, method: str, params: dict[str, Any]) -> None:
        self.send(
            {
                "jsonrpc": "2.0",
                "id": identifier,
                "method": method,
                "params": params,
            }
        )

    def _read_more(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        readable, _, _ = select.select([self.stdout.fileno()], [], [], remaining)
        if not readable:
            raise TimeoutError
        chunk = os.read(self.stdout.fileno(), 65536)
        if not chunk:
            raise ValidationFailure(
                "sourcekit-lsp closed stdout\n" + "\n".join(self.stderr_lines[-80:])
            )
        self.buffer.extend(chunk)

    def read_message(self, timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while b"\r\n\r\n" not in self.buffer:
            self._read_more(deadline)
        raw_headers, remainder = self.buffer.split(b"\r\n\r\n", 1)
        content_length: int | None = None
        for raw_header in raw_headers.split(b"\r\n"):
            name, separator, value = raw_header.partition(b":")
            if separator and name.lower() == b"content-length":
                content_length = int(value.strip())
        if content_length is None:
            raise ValidationFailure("sourcekit-lsp response omitted Content-Length")
        self.buffer = bytearray(remainder)
        while len(self.buffer) < content_length:
            self._read_more(deadline)
        payload = bytes(self.buffer[:content_length])
        del self.buffer[:content_length]
        decoded = json.loads(payload)
        if not isinstance(decoded, dict):
            raise ValidationFailure("sourcekit-lsp sent a non-object message")
        return decoded

    def response(self, identifier: int, timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            message = self.read_message(max(0.001, deadline - time.monotonic()))
            if message.get("method") == "textDocument/publishDiagnostics":
                params = message.get("params", {})
                uri = params.get("uri")
                diagnostics = params.get("diagnostics")
                if isinstance(uri, str) and isinstance(diagnostics, list):
                    self.diagnostics[uri] = diagnostics
                continue
            if message.get("id") != identifier:
                continue
            if "error" in message:
                raise ValidationFailure(
                    f"sourcekit-lsp request {identifier} failed: {message['error']}"
                )
            return message

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


class ProductValidator:
    def __init__(
        self, toolchain: pathlib.Path, platform: str, work_directory: pathlib.Path
    ) -> None:
        self.toolchain = toolchain.resolve()
        self.bin = self.toolchain / "bin"
        self.platform = platform
        self.work = work_directory.resolve()
        if self.work.exists():
            shutil.rmtree(self.work)
        self.work.mkdir(parents=True)
        home = self.work / "home"
        temporary = self.work / "tmp"
        home.mkdir()
        temporary.mkdir()
        self.environment = {
            "HOME": str(home),
            "USER": os.environ.get("USER", "nucleus"),
            "TMPDIR": str(temporary),
            "PATH": os.pathsep.join((str(self.bin), "/usr/bin", "/bin")),
            # SWIFT_EXEC selects the compiler driver used by SwiftPM and
            # SwiftBuild. The `swift` executable selects interpreter mode and
            # can return success without emitting a requested manifest binary.
            "SWIFT_EXEC": str(self.bin / "swiftc"),
            "SOURCEKIT_TOOLCHAIN_PATH": str(self.toolchain),
        }
        if platform == "macos" and "SDKROOT" in os.environ:
            self.environment["SDKROOT"] = os.environ["SDKROOT"]

    def run(
        self,
        *arguments: str | pathlib.Path,
        cwd: pathlib.Path | None = None,
        timeout: float = 120,
    ) -> subprocess.CompletedProcess[str]:
        command = [str(argument) for argument in arguments]
        print("+ " + " ".join(command), flush=True)
        result = subprocess.run(
            command,
            cwd=cwd,
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        if result.returncode != 0:
            raise ValidationFailure(
                f"command exited with {result.returncode}: {' '.join(command)}"
            )
        return result

    def validate_versions(self) -> None:
        checks = {
            "sourcekit-lsp": ("--help",),
            "swift-format": ("--version",),
            "docc": ("--help",),
            "wasmkit": ("--version",),
        }
        for executable, arguments in checks.items():
            output = self.run(self.bin / executable, *arguments).stdout.strip()
            if not output:
                raise ValidationFailure(
                    f"{executable} {' '.join(arguments)} produced no output"
                )

    def validate_swift_format(self) -> None:
        source = self.work / "format" / "Unformatted.swift"
        write(source, "struct Example{let value:Int}\n")
        self.run(self.bin / "swift-format", "format", "--in-place", source)
        formatted = source.read_text(encoding="utf-8")
        if "struct Example {" not in formatted or "let value: Int" not in formatted:
            raise ValidationFailure("swift-format did not produce the expected formatting")
        self.run(self.bin / "swift-format", "lint", "--strict", source)

    def validate_docc(self) -> None:
        catalog = self.work / "docc" / "NucleusSmoke.docc"
        archive = self.work / "docc" / "NucleusSmoke.doccarchive"
        write(
            catalog / "NucleusSmoke.md",
            "# Nucleus Smoke\n\nA functional Swift-DocC conversion test.\n",
        )
        self.run(
            self.bin / "docc",
            "convert",
            catalog,
            "--fallback-display-name",
            "Nucleus Smoke",
            "--fallback-bundle-identifier",
            "org.nucleustos.toolchain-smoke",
            "--fallback-bundle-version",
            "1",
            "--output-path",
            archive,
        )
        if not (archive / "index.html").is_file() or not (archive / "data").is_dir():
            raise ValidationFailure("DocC did not emit a valid documentation archive")

    def validate_wasmkit(self) -> None:
        module = self.work / "wasmkit" / "empty.wasm"
        write(module, b"\x00asm\x01\x00\x00\x00")
        self.run(self.bin / "wasmkit", "run", module)

    def validate_cxx_interop_test_runner(self) -> None:
        package = self.work / "cxx-interop-test-runner"
        write(
            package / "Package.swift",
            """// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CxxInteropTestRunner",
    products: [.library(name: "Example", targets: ["Example"])],
    targets: [
        .target(name: "Example"),
        .testTarget(
            name: "ExampleTests",
            dependencies: ["Example"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)
""",
        )
        write(
            package / "Sources" / "Example" / "Example.swift",
            "public struct Example { public init() {} }\n",
        )
        write(
            package / "Tests" / "ExampleTests" / "ExampleTests.swift",
            """import Testing
import Example

@Test func exampleExists() {
    _ = Example()
}
""",
        )
        self.run(
            self.bin / "swift",
            "test",
            "--package-path",
            package,
            timeout=300,
        )

    def create_lsp_package(self) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
        package = self.work / "sourcekit-lsp" / "NucleusLSPPackage"
        write(
            package / "Package.swift",
            """// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NucleusLSPPackage",
    products: [.library(name: "Greeter", targets: ["Greeter"])],
    targets: [
        .target(name: "Greeter"),
        .executableTarget(name: "App", dependencies: ["Greeter"]),
    ]
)
""",
        )
        library = package / "Sources" / "Greeter" / "Greeter.swift"
        application = package / "Sources" / "App" / "main.swift"
        write(
            library,
            """public struct Greeter {
    public init() {}
    public func message() -> String { "hello" }
}
""",
        )
        write(
            application,
            """import Greeter

let greeter = Greeter()
print(greeter.message())
""",
        )
        return package, library, application

    def validate_sourcekit_lsp(self) -> None:
        package, library, application = self.create_lsp_package()
        self.run(self.bin / "swift", "build", "--package-path", package, timeout=300)

        process = subprocess.Popen(
            [str(self.bin / "sourcekit-lsp")],
            cwd=package,
            env=self.environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        client = LSPClient(process)
        root_uri = package.as_uri()
        library_uri = library.as_uri()
        application_uri = application.as_uri()
        try:
            client.request(
                1,
                "initialize",
                {
                    "processId": os.getpid(),
                    "rootUri": root_uri,
                    "workspaceFolders": [
                        {"uri": root_uri, "name": "NucleusLSPPackage"}
                    ],
                    "capabilities": {
                        "textDocument": {
                            "definition": {},
                            "documentSymbol": {},
                            "diagnostic": {},
                        }
                    },
                },
            )
            initialize = client.response(1, 30)
            capabilities = initialize.get("result", {}).get("capabilities", {})
            client.notify("initialized", {})
            for uri, text in (
                (library_uri, library.read_text(encoding="utf-8")),
                (application_uri, application.read_text(encoding="utf-8")),
            ):
                client.notify(
                    "textDocument/didOpen",
                    {
                        "textDocument": {
                            "uri": uri,
                            "languageId": "swift",
                            "version": 1,
                            "text": text,
                        }
                    },
                )

            symbols: list[Any] = []
            for attempt in range(20):
                identifier = 100 + attempt
                client.request(
                    identifier,
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": library_uri}},
                )
                result = client.response(identifier, 10).get("result")
                if isinstance(result, list) and result:
                    symbols = result
                    break
                time.sleep(0.25)
            if not symbols:
                raise ValidationFailure("SourceKit-LSP returned no document symbols")

            application_text = application.read_text(encoding="utf-8").splitlines()
            definition_line = next(
                index for index, line in enumerate(application_text) if "Greeter()" in line
            )
            definition_character = application_text[definition_line].index("Greeter") + 1
            definition: Any = None
            for attempt in range(40):
                identifier = 200 + attempt
                client.request(
                    identifier,
                    "textDocument/definition",
                    {
                        "textDocument": {"uri": application_uri},
                        "position": {
                            "line": definition_line,
                            "character": definition_character,
                        },
                    },
                )
                definition = client.response(identifier, 10).get("result")
                if definition:
                    break
                time.sleep(0.5)
            if not definition or "Greeter.swift" not in json.dumps(definition):
                raise ValidationFailure(
                    "SourceKit-LSP did not resolve a definition across package targets"
                )

            if capabilities.get("diagnosticProvider") is not None:
                client.request(
                    300,
                    "textDocument/diagnostic",
                    {"textDocument": {"uri": application_uri}},
                )
                diagnostic_result = client.response(300, 20).get("result")
                if not isinstance(diagnostic_result, dict):
                    raise ValidationFailure(
                        "SourceKit-LSP returned an invalid diagnostic response"
                    )
            elif application_uri not in client.diagnostics:
                deadline = time.monotonic() + 20
                while application_uri not in client.diagnostics and time.monotonic() < deadline:
                    message = client.read_message(deadline - time.monotonic())
                    if message.get("method") == "textDocument/publishDiagnostics":
                        params = message.get("params", {})
                        uri = params.get("uri")
                        diagnostics = params.get("diagnostics")
                        if isinstance(uri, str) and isinstance(diagnostics, list):
                            client.diagnostics[uri] = diagnostics
                if application_uri not in client.diagnostics:
                    raise ValidationFailure(
                        "SourceKit-LSP did not publish diagnostics for the open document"
                    )

            client.request(400, "shutdown", {})
            client.response(400, 10)
            client.notify("exit", {})
            process.wait(timeout=10)
            if process.returncode != 0:
                raise ValidationFailure(
                    f"sourcekit-lsp exited with {process.returncode}\n"
                    + "\n".join(client.stderr_lines[-80:])
                )
        finally:
            client.close()

    def validate(self) -> None:
        self.validate_versions()
        self.validate_cxx_interop_test_runner()
        self.validate_swift_format()
        self.validate_docc()
        self.validate_wasmkit()
        self.validate_sourcekit_lsp()
        print("toolchain functional validation passed")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", type=pathlib.Path, required=True)
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument("--work-directory", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        ProductValidator(
            arguments.toolchain, arguments.platform, arguments.work_directory
        ).validate()
    except (OSError, subprocess.SubprocessError, TimeoutError, ValidationFailure) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
