/**
 * Nucleus LogBox overlay.
 *
 * Listens for native "showLogBox"/"hideLogBox" device events and renders
 * the standard React Native LogBox inspector as an absolute overlay.
 */

import * as React from 'react';

import View from 'react-native/Libraries/Components/View/View';
import StyleSheet from 'react-native/Libraries/StyleSheet/StyleSheet';
import RCTDeviceEventEmitter from 'react-native/Libraries/EventEmitter/RCTDeviceEventEmitter';

const LogBoxInspectorContainer =
  require('react-native/Libraries/LogBox/LogBoxInspectorContainer').default;

export default function LogBoxOverlay(): React.Node {
  const [visible, setVisible] = React.useState(false);

  React.useEffect(() => {
    const showSub = RCTDeviceEventEmitter.addListener('showLogBox', () => {
      setVisible(true);
    });
    const hideSub = RCTDeviceEventEmitter.addListener('hideLogBox', () => {
      setVisible(false);
    });
    return () => {
      showSub.remove();
      hideSub.remove();
    };
  }, []);

  if (!visible) {
    return null;
  }

  return (
    <View pointerEvents="box-none" style={styles.overlay}>
      <LogBoxInspectorContainer />
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 9999,
  },
});

