import React, {createContext,useContext} from 'react';
export const WorkspaceContext=createContext<string|null>(null);
export function useWorkspace(){const value=useContext(WorkspaceContext);if(!value)throw Error('MemberCard requires WorkspaceContext.Provider');return value;}
