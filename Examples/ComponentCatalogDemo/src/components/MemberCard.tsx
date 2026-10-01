import React from 'react';
import {useWorkspace} from '../context';
import {Badge} from './Badge';
type MemberCardProps={name:string;role?:string;online?:boolean};
export function MemberCard({name,role='Product designer',online=true}:MemberCardProps){const workspace=useWorkspace();return <div className="ns-member"><div className="ns-avatar">{name.slice(0,2).toUpperCase()}</div><div><strong>{name}</strong><p>{role} · {workspace}</p><Badge tone={online?'success':'neutral'}>{online?'Available':'Offline'}</Badge></div></div>}
