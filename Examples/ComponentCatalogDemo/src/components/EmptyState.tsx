import React from 'react';
import {Button} from './Button';
type EmptyStateProps={title:string;description:string;actionLabel?:string;onAction?:()=>void};
export function EmptyState({title,description,actionLabel='Create project',onAction}:EmptyStateProps){return <div className="ns-empty"><div>◈</div><h2>{title}</h2><p>{description}</p><Button onClick={onAction}>{actionLabel}</Button></div>}
