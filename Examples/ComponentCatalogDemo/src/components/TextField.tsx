import React from 'react';
type TextFieldProps = {label: string; placeholder?: string; error?: string; disabled?: boolean; onChange?: (value:string)=>void};
export function TextField({label,placeholder='you@company.com',error,disabled=false,onChange}:TextFieldProps){return <label className="ns-field"><strong>{label}</strong><input placeholder={placeholder} disabled={disabled} aria-invalid={Boolean(error)} onChange={e=>onChange?.(e.target.value)}/>{error&&<span>{error}</span>}</label>}
