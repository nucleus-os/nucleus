let aospPackageValidationProgram = #"""
    import argparse
    import concurrent.futures
    import pathlib
    import re
    import shutil
    import subprocess
    import sys
    import zipfile


    def parse_arguments():
        parser = argparse.ArgumentParser()
        parser.add_argument("--archive", required=True)
        parser.add_argument("--scratch", required=True)
        parser.add_argument("--apksigner", required=True)
        parser.add_argument("--avbtool", required=True)
        parser.add_argument("--release-key", required=True)
        parser.add_argument("--certificate-sha256", required=True)
        parser.add_argument("--minimum-sdk", required=True)
        parser.add_argument("--workers", required=True, type=int)
        return parser.parse_args()


    def checked(command):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            raise RuntimeError(
                f"command failed ({result.returncode}): {' '.join(command)}"
                + (f"\n{detail}" if detail else "")
            )
        return result.stdout


    def safe_package_entries(archive):
        packages = []
        extensions = set()
        for info in archive.infolist():
            path = pathlib.PurePosixPath(info.filename)
            extension = path.suffix.lower()
            if extension in {".apk", ".apex", ".capex"}:
                extensions.add(extension)
            if extension not in {".apk", ".apex"}:
                continue
            if path.is_absolute() or ".." in path.parts or info.is_dir():
                raise RuntimeError(f"unsafe package archive entry: {info.filename}")
            packages.append((info, path))
        if ".apk" not in extensions or ".apex" not in extensions:
            raise RuntimeError("signed target-files must contain APKs and APEXes")
        if ".capex" in extensions:
            raise RuntimeError("signed target-files must not contain CAPEXes")
        return sorted(packages, key=lambda item: str(item[1]))


    def extract_packages(archive, entries, destination):
        packages = []
        for info, relative in entries:
            output = destination.joinpath(*relative.parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, output.open("wb") as target:
                shutil.copyfileobj(source, target)
            packages.append(output)
        return packages


    def verify_package(index, package, arguments):
        output = checked(
            [
                arguments.apksigner,
                "verify",
                "--print-certs",
                "--min-sdk-version",
                arguments.minimum_sdk,
                str(package),
            ]
        )
        digests = [
            match.lower()
            for match in re.findall(
                r"certificate SHA-256 digest:\s*([0-9a-fA-F]+)", output
            )
        ]
        if digests != [arguments.certificate_sha256.lower()]:
            raise RuntimeError(
                "package does not carry exactly the Nucleus release certificate: "
                f"{package}"
            )

        if package.suffix.lower() == ".apex":
            payload = pathlib.Path(arguments.scratch) / f"apex-payload-{index}.img"
            with zipfile.ZipFile(package) as apex:
                try:
                    info = apex.getinfo("apex_payload.img")
                except KeyError as error:
                    raise RuntimeError(f"APEX has no payload image: {package}") from error
                with apex.open(info) as source, payload.open("wb") as target:
                    shutil.copyfileobj(source, target)
            try:
                checked(
                    [
                        arguments.avbtool,
                        "verify_image",
                        "--image",
                        str(payload),
                        "--key",
                        arguments.release_key,
                    ]
                )
            finally:
                payload.unlink(missing_ok=True)
        return package


    def main():
        arguments = parse_arguments()
        if arguments.workers <= 0:
            raise RuntimeError("workers must be greater than zero")
        scratch = pathlib.Path(arguments.scratch)
        packages_root = scratch / "packages"
        packages_root.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(arguments.archive) as archive:
            packages = extract_packages(
                archive, safe_package_entries(archive), packages_root
            )
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=arguments.workers
        ) as executor:
            list(
                executor.map(
                    lambda item: verify_package(item[0], item[1], arguments),
                    enumerate(packages),
                )
            )
        apex_count = sum(package.suffix.lower() == ".apex" for package in packages)
        payload_label = "APEX payload" if apex_count == 1 else "APEX payloads"
        print(f"verified {len(packages)} packages ({apex_count} {payload_label})")


    if __name__ == "__main__":
        try:
            main()
        except Exception as error:
            print(error, file=sys.stderr)
            sys.exit(1)
    """#
