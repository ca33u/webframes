// A read-only router for isolated previews. Navigation is reported, never sent
// to the app's server. Server actions are independently blocked by the helper.
function report(name,value=''){
  if(typeof window==='undefined')return;
  const id=new URLSearchParams(location.search).get('id');
  parent.postMessage({webframes:true,id,kind:'event',detail:{name:'Navigation · '+name,value:String(value)}},location.origin);
}
const router={push:url=>report('push',url),replace:url=>report('replace',url),refresh:()=>report('refresh'),back:()=>report('back'),forward:()=>report('forward'),prefetch:()=>Promise.resolve()};
export const useRouter=()=>router;
export const usePathname=()=>'/';
export const useParams=()=>({});
export const useSearchParams=()=>new URLSearchParams();
export const useSelectedLayoutSegment=()=>null;
export const useSelectedLayoutSegments=()=>[];
export function redirect(url){throw Error(`Redirect to ${url} requires the live page.`);}
export const permanentRedirect=redirect;
export function notFound(){throw Error('This component requested a not-found page. Supply its required props.');}
