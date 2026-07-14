import React from "react";
import {
  AppRegistry,
  Text,
  View,
  Pressable,
  DeviceEventEmitter,
  TurboModuleRegistry,
} from "react-native";

// The Nucleus shell bar — the Phase-4 vertical slice. A layer-shell top strip rendering a
// live clock (left) and a taskbar of the compositor's windows (center). Window snapshots
// arrive native→JS over foreign-toplevel via the facade's "nucleusShellWindows" device event
// (DeviceEventEmitter); tapping a task sends a JS→native action back through the facade's
// NucleusHostCommand seam (activate). Two halves of the same bidirectional bridge.
//
// This reconstitutes the compositor's old in-process NucleusUI menu bar as a React component
// drawing to its own layer-shell surface — a different program from an embedded overlay.

// The facade's JS→native command module (registered in registerCoreTurboModules). invoke(
// command, argsJson) reaches the shell's installed handler → the Wayland foreign-toplevel client.
const HostCommand = TurboModuleRegistry.get("NucleusHostCommand");

const HEIGHT = 28;

function formatTime(date) {
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function Clock() {
  const [now, setNow] = React.useState(() => formatTime(new Date()));
  React.useEffect(() => {
    const id = setInterval(() => setNow(formatTime(new Date())), 15000);
    return () => clearInterval(id);
  }, []);
  return <Text style={styles.clock}>{now}</Text>;
}

// The foreign-toplevel window list. The native side pushes snapshots via a global emit hook
// (see nucleus_shell_emit_windows); we subscribe on mount and translate taps into activate.
function Taskbar() {
  const [windows, setWindows] = React.useState([]);
  React.useEffect(() => {
    const sub = DeviceEventEmitter.addListener("nucleusShellWindows", (json) => {
      try {
        setWindows(JSON.parse(json));
      } catch {
        setWindows([]);
      }
    });
    return () => sub.remove();
  }, []);

  return (
    <View style={styles.taskbar}>
      {windows.map((w) => (
        <Pressable
          key={String(w.id)}
          onPress={() =>
            HostCommand?.invoke("activate", JSON.stringify({ id: String(w.id) }))
          }
          style={[styles.task, w.activated && styles.taskActive]}
        >
          <Text
            numberOfLines={1}
            style={[styles.taskLabel, w.minimized && styles.taskLabelDim]}
          >
            {w.title || w.appId || "Untitled"}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

function Bar() {
  return (
    <View nativeID="bar-root" style={styles.root}>
      <Taskbar />
      <Clock />
    </View>
  );
}

const styles = {
  root: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    height: HEIGHT,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 12,
    backgroundColor: "rgba(14, 16, 21, 0.72)",
  },
  clock: { color: "#f5f6f8", fontSize: 13, lineHeight: HEIGHT },
  taskbar: { flexDirection: "row", alignItems: "center", flexShrink: 1 },
  task: {
    height: 20,
    maxWidth: 180,
    marginRight: 6,
    paddingHorizontal: 8,
    borderRadius: 5,
    justifyContent: "center",
    backgroundColor: "rgba(255, 255, 255, 0.06)",
  },
  taskActive: { backgroundColor: "rgba(120, 160, 255, 0.28)" },
  taskLabel: { color: "#e6e8ec", fontSize: 12 },
  taskLabelDim: { color: "#9aa0aa" },
};

AppRegistry.registerComponent("bar", () => Bar);
