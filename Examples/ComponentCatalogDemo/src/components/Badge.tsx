import React from 'react';
type BadgeProps={children:string;tone?:'success'|'warning'|'neutral'};
export function Badge({children,tone='success'}:BadgeProps){return <span className={'ns-badge '+tone}><span>●</span> {children}</span>}
