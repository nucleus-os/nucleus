// InputEventNormalize — translate libinput events into the compositor's wire
// `WireEventRecord` stream. It produces the Quartz-shaped records
// (kind + flags + absolute location + packed `data0..3`) the Swift `EventServer`
// already consumes, so the dispatch path is unchanged below this point.
//
// Pure translation — it never advances stream state. The caller threads the
// current cursor/flags/button snapshot in and applies the accepted state after the
// future tap/filter points run (mirroring the central dispatcher's contract).

import NucleusCompositorInputC
import NucleusCompositorServerTypes

/// The stream state a translation reads: the central cursor/flags plus the button
/// state that decides whether motion is a move or a drag.
struct InputStreamSnapshot {
    var cursorX: Double = 0
    var cursorY: Double = 0
    var flags: UInt64 = 0
    var leftDown: Bool = false
    var rightDown: Bool = false
    var otherCount: UInt8 = 0

    var dragKind: WireEventKind {
        if leftDown { return .leftMouseDragged }
        if rightDown { return .rightMouseDragged }
        if otherCount > 0 { return .otherMouseDragged }
        return .mouseMoved
    }
}

/// Up to three records (a scroll event can carry both axes) plus whether a
/// `wl_pointer.frame` must follow the batch.
struct NormalizedEventBatch {
    var records: [WireEventRecord] = []
    var needsPointerFrame: Bool = false
}

struct TouchCoordinateSpace {
    var x: Double
    var y: Double
    var width: UInt32
    var height: UInt32
}

enum InputEventNormalize {
    private static func timestampNs(msec: UInt32) -> UInt64 { UInt64(msec) &* 1_000_000 }

    private static func record(kind: WireEventKind, snapshot: InputStreamSnapshot,
                               timeMsec: UInt32, x: Double, y: Double) -> WireEventRecord {
        var r = WireEventRecord()
        r.kind = kind
        r.flags = snapshot.flags
        r.timestampNs = timestampNs(msec: timeMsec)
        r.x = x
        r.y = y
        return r
    }

    static func translate(_ event: OpaquePointer, snapshot: InputStreamSnapshot,
                          scale: Double, touchSpace: TouchCoordinateSpace? = nil) -> NormalizedEventBatch {
        let type = libinput_event_get_type(event)
        let s = scale > 0 ? scale : 1.0
        var batch = NormalizedEventBatch()

        switch type {
        case LIBINPUT_EVENT_KEYBOARD_KEY:
            guard let kb = libinput_event_get_keyboard_event(event) else { return batch }
            let pressed = libinput_event_keyboard_get_key_state(kb) == LIBINPUT_KEY_STATE_PRESSED
            let keycode = libinput_event_keyboard_get_key(kb)
            let seatCount = libinput_event_keyboard_get_seat_key_count(kb)
            var r = record(kind: pressed ? .keyDown : .keyUp, snapshot: snapshot,
                           timeMsec: libinput_event_keyboard_get_time(kb),
                           x: snapshot.cursorX, y: snapshot.cursorY)
            r.data0 = UInt64(keycode)
            r.data1 = 0  // not a repeat
            r.data2 = UInt64(seatCount)
            batch.records.append(r)

        case LIBINPUT_EVENT_POINTER_MOTION:
            guard let ptr = libinput_event_get_pointer_event(event) else { return batch }
            let dx = libinput_event_pointer_get_dx(ptr) / s
            let dy = libinput_event_pointer_get_dy(ptr) / s
            // Unaccelerated deltas are pre-acceleration; the output scale is
            // acceleration-independent, so the same divisor applies to both pairs.
            let dxU = libinput_event_pointer_get_dx_unaccelerated(ptr) / s
            let dyU = libinput_event_pointer_get_dy_unaccelerated(ptr) / s
            var r = record(kind: snapshot.dragKind, snapshot: snapshot,
                           timeMsec: libinput_event_pointer_get_time(ptr),
                           x: snapshot.cursorX + dx, y: snapshot.cursorY + dy)
            r.data0 = dx.bitPattern
            r.data1 = dy.bitPattern
            r.data2 = dxU.bitPattern
            r.data3 = dyU.bitPattern
            batch.records.append(r)
            batch.needsPointerFrame = true

        case LIBINPUT_EVENT_POINTER_BUTTON:
            guard let ptr = libinput_event_get_pointer_event(event) else { return batch }
            let pressed = libinput_event_pointer_get_button_state(ptr) == LIBINPUT_BUTTON_STATE_PRESSED
            let button = libinput_event_pointer_get_button(ptr)
            var r = record(kind: buttonKind(button: button, pressed: pressed), snapshot: snapshot,
                           timeMsec: libinput_event_pointer_get_time(ptr),
                           x: snapshot.cursorX, y: snapshot.cursorY)
            r.data0 = UInt64(button)
            r.data1 = 1  // click_state
            batch.records.append(r)
            batch.needsPointerFrame = true

        case LIBINPUT_EVENT_POINTER_SCROLL_WHEEL,
             LIBINPUT_EVENT_POINTER_SCROLL_FINGER,
             LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS:
            guard let ptr = libinput_event_get_pointer_event(event) else { return batch }
            let isWheel = type == LIBINPUT_EVENT_POINTER_SCROLL_WHEEL
            let source: UInt64 = isWheel ? 0 : (type == LIBINPUT_EVENT_POINTER_SCROLL_FINGER ? 1 : 2)
            let timeMsec = libinput_event_pointer_get_time(ptr)
            for axis in [LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL] {
                guard libinput_event_pointer_has_axis(ptr, axis) != 0 else { continue }
                let delta = libinput_event_pointer_get_scroll_value(ptr, axis)
                var value120: Int32 = 0
                if isWheel {
                    let v120 = libinput_event_pointer_get_scroll_value_v120(ptr, axis)
                    value120 = Int32(v120.rounded())
                    // Wheel zero-delta + zero-v120 is not a real notch.
                    if delta == 0.0 && value120 == 0 { continue }
                }
                // Finger/continuous zero-delta is meaningful (emits axis_stop).
                let orientation: UInt64 = axis == LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL ? 0 : 1
                var r = record(kind: .scrollWheel, snapshot: snapshot, timeMsec: timeMsec,
                               x: snapshot.cursorX, y: snapshot.cursorY)
                r.data0 = delta.bitPattern
                r.data1 = UInt64(UInt32(bitPattern: value120))
                r.data2 = orientation
                r.data3 = source
                batch.records.append(r)
            }
            batch.needsPointerFrame = !batch.records.isEmpty

        case LIBINPUT_EVENT_TOUCH_DOWN, LIBINPUT_EVENT_TOUCH_MOTION:
            guard let touch = libinput_event_get_touch_event(event), let space = touchSpace,
                  space.width > 0, space.height > 0 else { return batch }
            let x = space.x + libinput_event_touch_get_x_transformed(touch, space.width)
            let y = space.y + libinput_event_touch_get_y_transformed(touch, space.height)
            var r = record(
                kind: type == LIBINPUT_EVENT_TOUCH_DOWN ? .touchDown : .touchMotion,
                snapshot: snapshot, timeMsec: libinput_event_touch_get_time(touch), x: x, y: y)
            r.data0 = UInt64(UInt32(bitPattern: libinput_event_touch_get_seat_slot(touch)))
            batch.records.append(r)

        case LIBINPUT_EVENT_TOUCH_UP:
            guard let touch = libinput_event_get_touch_event(event) else { return batch }
            var r = record(kind: .touchUp, snapshot: snapshot,
                           timeMsec: libinput_event_touch_get_time(touch),
                           x: snapshot.cursorX, y: snapshot.cursorY)
            r.data0 = UInt64(UInt32(bitPattern: libinput_event_touch_get_seat_slot(touch)))
            batch.records.append(r)

        case LIBINPUT_EVENT_TOUCH_CANCEL:
            batch.records.append(record(kind: .touchCancel, snapshot: snapshot,
                                        timeMsec: 0, x: snapshot.cursorX, y: snapshot.cursorY))

        case LIBINPUT_EVENT_TOUCH_FRAME:
            batch.records.append(record(kind: .touchFrame, snapshot: snapshot,
                                        timeMsec: 0, x: snapshot.cursorX, y: snapshot.cursorY))

        default:
            break
        }
        return batch
    }

    /// evdev BTN_LEFT (272) / BTN_RIGHT (273) map to the left/right kinds; all else
    /// is an "other" button.
    private static func buttonKind(button: UInt32, pressed: Bool) -> WireEventKind {
        switch button {
        case 272: return pressed ? .leftMouseDown : .leftMouseUp
        case 273: return pressed ? .rightMouseDown : .rightMouseUp
        default: return pressed ? .otherMouseDown : .otherMouseUp
        }
    }
}
