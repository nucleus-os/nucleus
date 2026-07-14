import React, { useEffect } from 'react';

import type { ContextMenuConfig } from './ContextMenuManager';
import { setContextMenu } from './ContextMenuManager';

export function ContextMenuConfigurator({ config }: { config: ContextMenuConfig }) {
  const json = JSON.stringify(config);

  useEffect(() => {
    setContextMenu(config);
  }, [json]);

  return null;
}
