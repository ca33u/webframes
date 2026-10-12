import React from 'react';

// Display the original asset; Next image optimization is unavailable here.
export default React.forwardRef(function PreviewImage({src,alt='',width,height,fill,style,priority,loading,quality,loader,unoptimized,placeholder,blurDataURL,onLoadingComplete,...props},ref) {
  const asset=typeof src==='object'&&src!==null?(src.default||src):null;
  return React.createElement('img',{
    ...props,ref,src:asset?.src||src,alt,
    width:fill?undefined:(width??asset?.width),height:fill?undefined:(height??asset?.height),
    loading:loading||(priority?'eager':'lazy'),decoding:'async',
    style:fill?{position:'absolute',inset:0,width:'100%',height:'100%',...style}:style,
    onLoad:event=>{props.onLoad?.(event);onLoadingComplete?.(event.currentTarget);}
  });
});
