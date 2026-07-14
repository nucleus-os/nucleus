/**
 * Nucleus Modal - behaves like iOS Modal.
 *
 * The standard Modal.js checks Platform.OS === 'ios' in several places to
 * determine whether to keep the modal mounted during close animation.
 * This shim makes Nucleus behave like iOS.
 */

'use strict';

import type {DirectEventHandler} from 'react-native/Libraries/Types/CodegenTypes';

import * as React from 'react';
import {
  View,
  StyleSheet,
  ScrollView,
} from 'react-native';

const ModalHostView = require('./ModalHostViewNativeComponent.nucleus').default;
const {RootTagContext} = require('react-native/Libraries/ReactNative/RootTag');
const AppContainer = require('react-native/Libraries/ReactNative/AppContainer').default;

let uniqueModalIdentifier = 0;

class Modal extends React.Component {
  static defaultProps = {
    visible: true,
    hardwareAccelerated: false,
  };

  static contextType = RootTagContext;

  constructor(props) {
    super(props);
    this._identifier = uniqueModalIdentifier++;
    this.state = {
      isRendered: props.visible === true,
    };
  }

  componentWillUnmount() {
    // Nucleus: behave like iOS
    this.setState({isRendered: false});
  }

  componentDidUpdate(prevProps) {
    if (prevProps.visible === false && this.props.visible === true) {
      this.setState({isRendered: true});
    }
  }

  // Nucleus: behave like iOS - keep rendering if isRendered is true
  _shouldShowModal() {
    return this.props.visible === true || this.state.isRendered === true;
  }

  render() {
    if (!this._shouldShowModal()) {
      return null;
    }

    // Nucleus: container is always transparent; backdrop (if any) is developer-provided.
    const containerStyles = {
      backgroundColor: 'transparent',
    };

    let animationType = this.props.animationType || 'none';

    let presentationStyle = this.props.presentationStyle;
    if (!presentationStyle) {
      presentationStyle = 'fullScreen';
      if (this.props.transparent === true) {
        presentationStyle = 'overFullScreen';
      }
    }

    const innerChildren = __DEV__ ? (
      <AppContainer rootTag={this.context}>{this.props.children}</AppContainer>
    ) : (
      this.props.children
    );

    const backdrop = this.props.backdrop ?? null;

    // Nucleus: behave like iOS - handle onDismiss from native
    const onDismiss = () => {
      this.setState({isRendered: false}, () => {
        if (this.props.onDismiss) {
          this.props.onDismiss();
        }
      });
    };

    return (
      <ModalHostView
        animationType={animationType}
        presentationStyle={presentationStyle}
        transparent={this.props.transparent}
        hardwareAccelerated={this.props.hardwareAccelerated}
        onRequestClose={this.props.onRequestClose}
        onShow={this.props.onShow}
        onDismiss={onDismiss}
        ref={this.props.modalRef}
        visible={this.props.visible}
        statusBarTranslucent={this.props.statusBarTranslucent}
        navigationBarTranslucent={this.props.navigationBarTranslucent}
        identifier={this._identifier}
        style={styles.modal}
        onStartShouldSetResponder={this._shouldSetResponder}
        supportedOrientations={this.props.supportedOrientations}
        onOrientationChange={this.props.onOrientationChange}
        testID={this.props.testID}>
        <ScrollView.Context.Provider value={null}>
          {backdrop ? (
            <View pointerEvents="box-none" style={styles.backdropLayer}>
              {backdrop}
            </View>
          ) : null}
          <View
            pointerEvents="box-none"
            style={[styles.container, containerStyles]}
            collapsable={false}>
            {innerChildren}
          </View>
        </ScrollView.Context.Provider>
      </ModalHostView>
    );
  }

  _shouldSetResponder() {
    return true;
  }
}

const styles = StyleSheet.create({
  modal: {
    position: 'absolute',
  },
  container: {
    // Fill the full-screen modal portal so children lay out + hit-test correctly.
    position: 'absolute',
    left: 0,
    right: 0,
    top: 0,
    bottom: 0,
    zIndex: 1,
  },
  backdropLayer: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 0,
  },
});

function Wrapper({ref, ...props}) {
  return <Modal {...props} modalRef={ref} />;
}

Wrapper.displayName = 'Modal';

export default Wrapper;
