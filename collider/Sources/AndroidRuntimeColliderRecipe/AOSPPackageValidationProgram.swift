let aospPackageValidationProgram = #"""
    import argparse
    import concurrent.futures
    import json
    import os
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
        parser.add_argument("--release-certificate", required=True)
        parser.add_argument("--vbmeta-image", required=True)
        parser.add_argument("--minimum-sdk", required=True)
        parser.add_argument("--workers", required=True, type=int)
        parser.add_argument("--summary", required=True)
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


    def verify_package(index, package, arguments, expected_digest):
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
        if digests != [expected_digest]:
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
        checked(
            [
                arguments.avbtool,
                "verify_image",
                "--image",
                arguments.vbmeta_image,
                "--key",
                arguments.release_key,
                "--follow_chain_partitions",
            ]
        )
        certificate_output = checked(
            [
                "openssl",
                "x509",
                "-in",
                arguments.release_certificate,
                "-noout",
                "-fingerprint",
                "-sha256",
            ]
        )
        if "=" not in certificate_output:
            raise RuntimeError("could not read the release certificate fingerprint")
        expected_digest = (
            certificate_output.split("=", 1)[1]
            .replace(":", "")
            .strip()
            .lower()
        )
        required_entries = [
            "SYSTEM/build.prop",
            "VENDOR/build.prop",
            "SYSTEM/etc/fonts.xml",
            "SYSTEM/etc/font_fallback.xml",
            "META/misc_info.txt",
        ]
        with zipfile.ZipFile(arguments.archive) as archive:
            archive_entries = archive.namelist()
            contents = {}
            for name in required_entries:
                try:
                    contents[name] = archive.read(name).decode("utf-8")
                except KeyError as error:
                    raise RuntimeError(
                        f"required target-files entry is missing: {name}"
                    ) from error
            packages = extract_packages(
                archive, safe_package_entries(archive), packages_root
            )
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=arguments.workers
        ) as executor:
            list(
                executor.map(
                    lambda item: verify_package(
                        item[0], item[1], arguments, expected_digest
                    ),
                    enumerate(packages),
                )
            )
        apex_count = sum(package.suffix.lower() == ".apex" for package in packages)
        summary = pathlib.Path(arguments.summary)
        candidate = summary.with_name(f".{summary.name}.candidate")
        with candidate.open("w", encoding="utf-8") as output:
            json.dump(
                {
                    "archiveEntries": archive_entries,
                    "systemBuildProperties": contents["SYSTEM/build.prop"],
                    "vendorBuildProperties": contents["VENDOR/build.prop"],
                    "fontConfigurations": {
                        name: contents[name]
                        for name in [
                            "SYSTEM/etc/fonts.xml",
                            "SYSTEM/etc/font_fallback.xml",
                        ]
                    },
                    "miscInfo": contents["META/misc_info.txt"],
                    "packageCount": len(packages),
                    "apexCount": apex_count,
                },
                output,
                separators=(",", ":"),
                sort_keys=True,
            )
        os.replace(candidate, summary)
        payload_label = "APEX payload" if apex_count == 1 else "APEX payloads"
        print(f"verified {len(packages)} packages ({apex_count} {payload_label})")


    if __name__ == "__main__":
        try:
            main()
        except Exception as error:
            print(error, file=sys.stderr)
            sys.exit(1)
    """#
