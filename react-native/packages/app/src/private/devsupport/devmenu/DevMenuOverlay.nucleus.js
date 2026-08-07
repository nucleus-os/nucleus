/**
 * Nucleus DevMenu overlay.
 *
 * Listens for native "showDevMenu" device events and renders a simple
 * modal overlay that invokes the DevMenu TurboModule actions.
 */

import * as React from 'react';

import Pressable from 'react-native/Libraries/Components/Pressable/Pressable';
import Text from 'react-native/Libraries/Text/Text';
import View from 'react-native/Libraries/Components/View/View';
import StyleSheet from 'react-native/Libraries/StyleSheet/StyleSheet';
import RCTDeviceEventEmitter from 'react-native/Libraries/EventEmitter/RCTDeviceEventEmitter';

import NativeDevMenu from 'react-native/src/private/devsupport/devmenu/specs/NativeDevMenu';
import NativeDevSettings from 'react-native/Libraries/NativeModules/specs/NativeDevSettings';
import Platform from 'react-native/Libraries/Utilities/Platform';

const PerfOverlay = require('../../../../Libraries/DevSupport/PerfOverlay.nucleus');

export default function DevMenuOverlay(): React.Node {
  const [visible, setVisible] = React.useState(false);
  const [hotReloadEnabled, setHotReloadEnabled] = React.useState(true); // HMR is enabled by default in dev
  const [profilingEnabled, setProfilingEnabled] = React.useState(false);
  const [perfOverlayEnabled, setPerfOverlayEnabled] = React.useState(false);

  React.useEffect(() => {
    const sub = RCTDeviceEventEmitter.addListener('showDevMenu', () => {
      setVisible(prev => !prev); // Toggle visibility
    });
    return () => sub.remove();
  }, []);

  React.useEffect(() => {
    if (!visible) return;
    try {
      setPerfOverlayEnabled(!!PerfOverlay.isEnabled?.());
    } catch (e) {
      setPerfOverlayEnabled(false);
    }
  }, [visible]);

  if (!visible) {
    return null;
  }

  const close = () => setVisible(false);

  // Determine keyboard shortcut prefix based on platform
  const isMac = Platform.OS === 'macos' || Platform.OS === 'ios';
  const cmdKey = isMac ? '⌘' : 'Ctrl+';

  return (
    <View style={styles.backdrop} pointerEvents="box-none">
      <Pressable style={styles.scrim} onPress={close} />
      <View style={styles.panel}>
        <Text style={styles.title}>Dev Menu</Text>
        <Text style={styles.subtitle}>
          {cmdKey}D to toggle • {cmdKey}R to reload
        </Text>

        <MenuButton
          label="Reload"
          hint={`${cmdKey}R`}
          onPress={() => { close(); NativeDevMenu.reload?.(); }}
        />
        <MenuButton
          label="Toggle Element Inspector"
          onPress={() => { close(); NativeDevSettings.toggleElementInspector?.(); }}
        />
        <MenuButton
          label="Hot Reloading"
          hint={hotReloadEnabled ? '✓ ON' : 'OFF'}
          onPress={() => {
            const newState = !hotReloadEnabled;
            setHotReloadEnabled(newState);
            close();
            NativeDevMenu.setHotLoadingEnabled?.(newState);
          }}
        />
        <MenuButton
          label="Profiling"
          hint={profilingEnabled ? '✓ ON' : 'OFF'}
          onPress={() => {
            const newState = !profilingEnabled;
            setProfilingEnabled(newState);
            close();
            NativeDevMenu.setProfilingEnabled?.(newState);
          }}
        />
        <MenuButton
          label="Perf Overlay"
          hint={perfOverlayEnabled ? '✓ ON' : 'OFF'}
          onPress={() => {
            const newState = !perfOverlayEnabled;
            setPerfOverlayEnabled(newState);
            close();
            try { PerfOverlay.setEnabled(newState); } catch (e) {}
          }}
        />

        <MenuButton label="Close" onPress={close} />
      </View>
    </View>
  );
}

function MenuButton({
  label,
  hint,
  onPress,
}: {
  label: string,
  hint?: string,
  onPress: () => void,
}) {
  return (
    <Pressable style={styles.button} onPress={onPress}>
      <View style={styles.buttonContent}>
        <Text style={styles.buttonText}>{label}</Text>
        {hint && <Text style={styles.buttonHint}>{hint}</Text>}
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    ...StyleSheet.absoluteFill,
    zIndex: 9998,
    justifyContent: 'center',
    alignItems: 'center',
  },
  scrim: {
    ...StyleSheet.absoluteFill,
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  panel: {
    minWidth: 280,
    paddingVertical: 12,
    paddingHorizontal: 16,
    backgroundColor: 'rgba(30,30,30,0.95)',
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.1)',
  },
  title: {
    fontSize: 16,
    fontWeight: '600',
    color: '#fff',
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 12,
    color: 'rgba(255,255,255,0.6)',
    marginBottom: 12,
  },
  button: {
    paddingVertical: 8,
  },
  buttonContent: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  buttonText: {
    fontSize: 14,
    color: '#fff',
  },
  buttonHint: {
    fontSize: 12,
    color: 'rgba(255,255,255,0.5)',
    fontWeight: '500',
  },
});
