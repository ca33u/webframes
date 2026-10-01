import React from 'react';
import {createRoot} from 'react-dom/client';
import {missingProps} from './preview-data.mjs';
const query=new URLSearchParams(location.search);const id=query.get('id');
const send=(kind,detail)=>parent.postMessage({webframes:true,id,kind,detail},location.origin);
class Boundary extends React.Component{
  state={error:null};static getDerivedStateFromError(error){return{error};}
  componentDidCatch(error){send('error',error.message);}
  render(){return this.state.error?<div role="alert" style={{padding:20,color:'#b42318',background:'#fff4f2',font:'13px system-ui',whiteSpace:'pre-wrap'}}>Needs setup · {this.state.error.message}</div>:this.props.children;}
}
const root=createRoot(document.getElementById('root'));
let Component,Wrapper,meta;
function render(state){
  const args={...state.args};
  send('loading', null);
  const missing = missingProps(meta, args);
  if (missing.length) {
    const message = 'Provide required props: ' + missing.join(', ');
    root.render(<div role="status" style={{padding:20,font:'13px system-ui',color:'#aaa'}}>Needs data · {message}. Open this component to edit Props or choose a saved example.</div>);
    send('error', message); return;
  }
  for(const p of meta.props)if(p.kind==='action')args[p.name]=(...values)=>send('event',{name:p.name,value:values.map(v=>v?.nativeEvent?'DOM event':typeof v==='object'?'Object':String(v)).join(', ')});
  document.documentElement.dataset.theme=state.theme||'light';document.documentElement.classList.toggle('dark',state.theme==='dark');
  document.documentElement.style.colorScheme=state.theme||'light';
  document.body.style.cssText=`margin:0;min-height:100vh;box-sizing:border-box;padding:24px;background:${state.background==='transparent'?'transparent':state.theme==='dark'?'#181a20':'#fff'};color:${state.theme==='dark'?'#f5f5f5':'#1b1e27'};font:14px system-ui;`;
  document.getElementById('root').style.cssText='min-height:calc(100vh - 48px);display:grid;place-items:center;min-width:0';
  root.render(<Boundary key={JSON.stringify(state)}><Content args={args} theme={state.theme}/></Boundary>);
}
function Content({args,theme}){React.useEffect(()=>send('rendered',null),[]);const child=<Component {...args}/>;return Wrapper?<Wrapper theme={theme}>{child}</Wrapper>:child;}
try{
 const manifest=await fetch('/catalog.json').then(r=>{if(!r.ok)throw Error('Catalogue unavailable');return r.json()});if(query.get('project')!==manifest.projectId)throw Error('This preview belongs to another project. Start its catalogue server to continue.');meta=manifest.components.find(c=>c.id===id);
 if(!meta)throw Error('Component is no longer in this project. Refresh the catalogue.');
 const registry=await import(/* @vite-ignore */ '/@id/__x00__virtual:webframes/'+encodeURIComponent(id));
 [Component,Wrapper]=await Promise.all([registry.load(),registry.wrapper()]);
 if(!Component)throw Error('Export could not be loaded.');
 let state={args:meta.defaults,theme:'light'};
 if(query.has('state'))state=JSON.parse(query.get('state'));
 render(state);send('ready',null);
 addEventListener('message',event=>{if(event.origin===location.origin && event.source===parent && event.data?.kind==='render')render(event.data.state);});
}catch(error){root.render(<div role="alert" style={{font:'13px system-ui',padding:20,color:'#b42318'}}>Needs setup · {error.message}</div>);send('error',error.message);}
addEventListener('click',event=>{if(event.target.closest?.('a[href]')){event.preventDefault();send('event',{name:'Navigation',value:'Open the live page to navigate.'});}},true);
addEventListener('submit',event=>event.preventDefault());
addEventListener('error',event=>send('error',event.message));
addEventListener('unhandledrejection',event=>send('error',String(event.reason?.message||event.reason)));
