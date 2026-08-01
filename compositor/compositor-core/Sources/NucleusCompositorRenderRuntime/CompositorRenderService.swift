package import NucleusCompositorRendererLinux
package import NucleusCompositorServer
package import NucleusRenderer

extension DRMScanoutPresenter: CompositorRenderService {
    package func importShm(
        previousIOSurfaceID: UInt32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        stride: UInt32,
        pixels: Span<UInt8>
    ) -> UInt32 {
        let id =
            previousIOSurfaceID != 0
            ? previousIOSurfaceID
            : allocSurfaceId()
        return registerSurfaceShm(
            iosurfaceID: UInt64(id),
            pixels: pixels,
            width: width,
            height: height,
            drmFormat: drmFormat,
            stride: stride
        ) ? id : 0
    }

    package func importDmabuf(_ request: RenderDmabufImport) -> UInt32 {
        guard let firstPlane = request.planes.first else { return 0 }
        let id =
            request.previousIOSurfaceID != 0
            ? request.previousIOSurfaceID
            : allocSurfaceId()
        let planes = request.planes.map {
            DmaBufPlane(
                fd: $0.fd,
                offset: UInt64($0.offset),
                rowPitch: UInt64($0.stride))
        }
        return registerSurfaceDmabuf(
            iosurfaceID: UInt64(id),
            fd: firstPlane.fd,
            width: request.width,
            height: request.height,
            drmFormat: request.drmFormat,
            modifier: request.modifier,
            planes: planes,
            acquire: request.acquire.map {
                DmaBufSyncPoint(handle: $0.handle, point: $0.point)
            },
            release: request.release.map {
                DmaBufSyncPoint(handle: $0.handle, point: $0.point)
            }
        ) ? id : 0
    }

    package func releaseIOSurface(_ id: UInt32) {
        guard id != 0 else { return }
        releaseSurfaceTexture(iosurfaceID: UInt64(id))
    }

    package func dmabufFormats() -> [RenderDmabufFormat] {
        dmabufSupportedFormats().map {
            RenderDmabufFormat(format: $0.format, modifier: $0.modifier)
        }
    }

    package func probeDmabuf(_ request: RenderDmabufProbe) -> Bool {
        guard let firstPlane = request.planes.first else { return false }
        return canImportSurfaceDmabuf(
            fd: firstPlane.fd,
            width: request.width,
            height: request.height,
            drmFormat: request.drmFormat,
            modifier: request.modifier,
            planes: request.planes.map {
                DmaBufPlane(
                    fd: $0.fd,
                    offset: UInt64($0.offset),
                    rowPitch: UInt64($0.stride))
            })
    }

    package func applyGamma(_ ramp: RenderGammaRamp) -> Bool {
        applyGamma(
            outputID: ramp.outputID,
            red: ramp.red,
            green: ramp.green,
            blue: ramp.blue)
    }

    package func beginCaptureOutput(
        outputID: UInt64,
        sourceRegion: RenderCaptureRegion?,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64? {
        beginCaptureOutputBGRA(
            outputID: outputID,
            sourceX: sourceRegion?.x ?? 0,
            sourceY: sourceRegion?.y ?? 0,
            sourceWidth: sourceRegion?.width ?? 0,
            sourceHeight: sourceRegion?.height ?? 0
        ) { capture in
            completion(
                capture.map {
                    RenderPixelCapture(
                        pixels: $0.pixels,
                        width: $0.width,
                        height: $0.height,
                        originX: $0.originX,
                        originY: $0.originY)
                })
        }
    }

    package func beginReadSurface(
        iosurfaceID: UInt32,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64? {
        beginReadSurfaceTextureBGRA(iosurfaceID: iosurfaceID) { capture in
            completion(
                capture.map {
                    RenderPixelCapture(
                        pixels: $0.pixels,
                        width: $0.width,
                        height: $0.height,
                        originX: $0.originX,
                        originY: $0.originY)
                })
        }
    }

    package func captureSurfaceSnapshot(
        iosurfaceID: UInt32
    ) -> RenderSnapshotResource? {
        guard
            let capture = captureSurfaceSnapshot(
                iosurfaceID: UInt64(iosurfaceID))
        else { return nil }
        return RenderSnapshotResource(
            handle: capture.handle,
            width: capture.width,
            height: capture.height)
    }

    package func beginCaptureOutput(
        to request: RenderDmabufCapture,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64? {
        guard let firstPlane = request.planes.first else { return nil }
        let region = request.sourceRegion
        return beginCaptureOutputToDmabuf(
            outputID: request.outputID,
            fd: firstPlane.fd,
            width: request.width,
            height: request.height,
            drmFormat: request.drmFormat,
            modifier: request.modifier,
            planes: request.planes.map {
                DmaBufPlane(
                    fd: $0.fd,
                    offset: UInt64($0.offset),
                    rowPitch: UInt64($0.stride))
            },
            sourceX: region?.x ?? 0,
            sourceY: region?.y ?? 0,
            sourceWidth: region?.width ?? 0,
            sourceHeight: region?.height ?? 0,
            overlayCursor: request.overlaysCursor,
            completion: completion)
    }
}
