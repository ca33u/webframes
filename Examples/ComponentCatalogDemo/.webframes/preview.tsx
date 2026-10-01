import React from 'react';
import '../src/styles.css';
import {WorkspaceContext} from '../src/context';
export function Wrapper({children,theme}){return <WorkspaceContext.Provider value="Northstar"><div className="northstar" data-theme={theme}>{children}</div></WorkspaceContext.Provider>}
