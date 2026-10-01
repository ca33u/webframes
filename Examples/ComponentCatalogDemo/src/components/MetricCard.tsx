import React from 'react';
type MetricCardProps = {label:string;value:string;change?:string;trend?:'up'|'down';loading?:boolean};
export function MetricCard({label,value,change='+12.8%',trend='up',loading=false}:MetricCardProps){return <section className="ns-card"><p>{label}</p><strong>{loading?'—':value}</strong><span className={trend}>{trend==='up'?'↗':'↘'} {change} <small>vs. last month</small></span></section>}
