/**
 * Nucleus dev AppContainer shim.
 *
 * Based on upstream AppContainer-dev, with Nucleus-only overlays for LogBox and
 * DevMenu rendered inside the root surface.
 */

import ReactNativeStyleAttributes from 'react-native/Libraries/Components/View/ReactNativeStyleAttributes';
import View from 'react-native/Libraries/Components/View/View';
import DebuggingOverlay from 'react-native/Libraries/Debugging/DebuggingOverlay';
import useSubscribeToDebuggingOverlayRegistry from 'react-native/Libraries/Debugging/useSubscribeToDebuggingOverlayRegistry';
import RCTDeviceEventEmitter from 'react-native/Libraries/EventEmitter/RCTDeviceEventEmitter';
import LogBoxNotificationContainer from 'react-native/Libraries/LogBox/LogBoxNotificationContainer';
import StyleSheet from 'react-native/Libraries/StyleSheet/StyleSheet';
import {RootTagContext, createRootTag} from 'react-native/Libraries/ReactNative/RootTag';
import * as React from 'react';
import {useRef} from 'react';

import LogBoxOverlay from '../../src/private/devsupport/logbox/LogBoxOverlay.nucleus';
import DevMenuOverlay from '../../src/private/devsupport/devmenu/DevMenuOverlay.nucleus';

const {useEffect, useState} = React;

const reactDevToolsHook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;

// Set up HMRClient toggle listener
if (__DEV__) {
  const HMRClient = require('react-native/Libraries/Utilities/HMRClient').default;
  RCTDeviceEventEmitter.addListener('setHotLoadingEnabled', (enabled) => {
    try {
      if (enabled) {
        HMRClient.enable();
        console.log('[HMR] Hot reloading enabled');
      } else {
        HMRClient.disable();
        console.log('[HMR] Hot reloading disabled');
      }
    } catch (e) {
      console.warn('[HMR] Failed to toggle hot loading:', e);
    }
  });
}

if (reactDevToolsHook) {
  reactDevToolsHook.resolveRNStyle =
    require('react-native/Libraries/StyleSheet/flattenStyle').default;
  reactDevToolsHook.nativeStyleEditorValidAttributes = Object.keys(
    ReactNativeStyleAttributes,
  );
}

const InspectorDeferred = ({
  inspectedViewRef,
  onInspectedViewRerenderRequest,
  reactDevToolsAgent,
}) => {
  const Inspector =
    require('react-native/src/private/devsupport/devmenu/elementinspector/Inspector').default;

  return (
    <Inspector
      inspectedViewRef={inspectedViewRef}
      onRequestRerenderApp={onInspectedViewRerenderRequest}
      reactDevToolsAgent={reactDevToolsAgent}
    />
  );
};

const ReactDevToolsOverlayDeferred = ({
  inspectedViewRef,
  reactDevToolsAgent,
}) => {
  const ReactDevToolsOverlay =
    require('react-native/src/private/devsupport/devmenu/elementinspector/ReactDevToolsOverlay').default;

  return (
    <ReactDevToolsOverlay
      inspectedViewRef={inspectedViewRef}
      reactDevToolsAgent={reactDevToolsAgent}
    />
  );
};

const AppContainer = ({
  children,
  fabric,
  initialProps,
  internal_excludeInspector = false,
  internal_excludeLogBox = false,
  rootTag,
  WrapperComponent,
  rootViewStyle,
}) => {
  const appContainerRootViewRef = useRef(null);
  const innerViewRef = useRef(null);
  const debuggingOverlayRef = useRef(null);

  useSubscribeToDebuggingOverlayRegistry(
    appContainerRootViewRef,
    debuggingOverlayRef,
  );

  const [key, setKey] = useState(0);
  const [shouldRenderInspector, setShouldRenderInspector] = useState(false);
  const [reactDevToolsAgent, setReactDevToolsAgent] =
    useState(reactDevToolsHook?.reactDevtoolsAgent);

  useEffect(() => {
    let inspectorSubscription = null;
    if (!internal_excludeInspector) {
      inspectorSubscription = RCTDeviceEventEmitter.addListener(
        'toggleElementInspector',
        () => setShouldRenderInspector(value => !value),
      );
    }

    let reactDevToolsAgentListener = null;
    if (reactDevToolsHook != null && reactDevToolsAgent == null) {
      reactDevToolsAgentListener = setReactDevToolsAgent;
      reactDevToolsHook.on?.('react-devtools', reactDevToolsAgentListener);
    }

    return () => {
      inspectorSubscription?.remove();

      if (
        reactDevToolsHook?.off != null &&
        reactDevToolsAgentListener != null
      ) {
        reactDevToolsHook.off('react-devtools', reactDevToolsAgentListener);
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  let innerView = (
    <View
      collapsable={reactDevToolsAgent == null && !shouldRenderInspector}
      pointerEvents="box-none"
      key={key}
      style={rootViewStyle || styles.container}
      ref={innerViewRef}>
      {children}
    </View>
  );

  if (WrapperComponent != null) {
    innerView = (
      <WrapperComponent initialProps={initialProps} fabric={fabric === true}>
        {innerView}
      </WrapperComponent>
    );
  }

  const onInspectedViewRerenderRequest = () => setKey(k => k + 1);

  return (
    <RootTagContext.Provider value={createRootTag(rootTag)}>
      <View
        ref={appContainerRootViewRef}
        style={rootViewStyle || styles.container}
        pointerEvents="box-none">
        {innerView}

        <DebuggingOverlay ref={debuggingOverlayRef} />

        {reactDevToolsAgent != null && (
          <ReactDevToolsOverlayDeferred
            inspectedViewRef={innerViewRef}
            reactDevToolsAgent={reactDevToolsAgent}
          />
        )}

        {shouldRenderInspector && (
          <InspectorDeferred
            inspectedViewRef={innerViewRef}
            onInspectedViewRerenderRequest={onInspectedViewRerenderRequest}
            reactDevToolsAgent={reactDevToolsAgent}
          />
        )}

        {!internal_excludeLogBox && <LogBoxNotificationContainer />}
        {!internal_excludeLogBox && <LogBoxOverlay />}
        <DevMenuOverlay />
      </View>
    </RootTagContext.Provider>
  );
};

const styles = StyleSheet.create({
  container: {flex: 1},
});

export default AppContainer;
