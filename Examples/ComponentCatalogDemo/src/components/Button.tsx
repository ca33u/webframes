import React from 'react';
type ButtonProps = {
  children: string;
  variant?: 'primary' | 'secondary' | 'danger';
  size?: 'small' | 'medium' | 'large';
  disabled?: boolean;
  loading?: boolean;
  onClick?: () => void;
};
export function Button({children, variant='primary', size='medium', disabled=false, loading=false, onClick}: ButtonProps) {
  return <button className={`ns-button ${variant} ${size}`} disabled={disabled || loading} onClick={onClick}>{loading?'◌ Working…':children}</button>;
}
