/**
 * Nucleus OverlayHostView native component (Fabric name only).
 *
 * @flow
 * @format
 */
'use strict';

import type {ViewProps} from 'react-native';
import type {
  DirectEventHandler,
  Int32,
  WithDefault,
} from 'react-native/Libraries/Types/CodegenTypes';
import type {HostComponent} from 'react-native';

import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

type OrientationChangeEvent = $ReadOnly<{
  orientation: 'portrait' | 'landscape',
}>;

type OverlayHostViewNativeProps = $ReadOnly<{
  ...ViewProps,

  animationType?: WithDefault<'none' | 'slide' | 'fade', 'none'>,
  presentationStyle?: WithDefault<
    'fullScreen' | 'pageSheet' | 'formSheet' | 'overFullScreen',
    'fullScreen',
  >,
  transparent?: WithDefault<boolean, false>,
  statusBarTranslucent?: WithDefault<boolean, false>,
  navigationBarTranslucent?: WithDefault<boolean, false>,
  hardwareAccelerated?: WithDefault<boolean, false>,
  onRequestClose?: ?DirectEventHandler<null>,
  onShow?: ?DirectEventHandler<null>,
  onDismiss?: ?DirectEventHandler<null>,
  visible?: WithDefault<boolean, false>,
  animated?: WithDefault<boolean, false>,
  allowSwipeDismissal?: WithDefault<boolean, false>,
  supportedOrientations?: WithDefault<
    $ReadOnlyArray<
      | 'portrait'
      | 'portrait-upside-down'
      | 'landscape'
      | 'landscape-left'
      | 'landscape-right',
    >,
    'portrait',
  >,
  onOrientationChange?: ?DirectEventHandler<OrientationChangeEvent>,
  identifier?: WithDefault<Int32, 0>,
}>;

export default (codegenNativeComponent<OverlayHostViewNativeProps>(
  'OverlayHostView',
  {
    interfaceOnly: true,
  },
): HostComponent<OverlayHostViewNativeProps>);
