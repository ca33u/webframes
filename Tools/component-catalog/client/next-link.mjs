import React from 'react';

export function previewHref(href) {
  if(typeof href==='string')return href;
  if(!href)return '';
  const query=new URLSearchParams();
  for(const [key,value] of Object.entries(href.query||{})) {
    for(const item of Array.isArray(value)?value:[value])if(item!=null)query.append(key,String(item));
  }
  const search=query.size?'?'+query.toString():(href.search||'');
  const hash=href.hash?(href.hash.startsWith('#')?href.hash:'#'+href.hash):'';
  return (href.pathname||'')+search+hash;
}

// The preview's click boundary reports navigation and keeps the preview open.
// No Next router, prefetch requests or project server are needed to render links.
export default React.forwardRef(function PreviewLink({href,as,prefetch,replace,scroll,shallow,locale,legacyBehavior,passHref,onNavigate,children,...props},ref) {
  const url=previewHref(as||href);
  if(legacyBehavior&&React.isValidElement(children))return React.cloneElement(children,{...props,ref,...(passHref||children.type==='a'?{href:url}:{})});
  return React.createElement('a',{...props,href:url,ref},children);
});
