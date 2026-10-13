package app.essazanov.webframes.capture;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Base64;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.HashSet;
import org.json.JSONArray;
import org.json.JSONObject;

/** Web Frames' local Android runner. No network permissions or third-party libraries. */
public final class CaptureInstrumentation extends Instrumentation {
    private Bundle arguments;
    private UiAutomation ui;
    private String appID;

    @Override public void onCreate(Bundle args) { super.onCreate(args); arguments = args; start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            JSONObject recipe = new JSONObject(new String(Base64.decode(arguments.getString("recipe"), Base64.DEFAULT), "UTF-8"));
            appID = recipe.getString("appBundleID");
            String runID = arguments.getString("runID");
            if (runID == null || !runID.matches("[A-Fa-f0-9-]{36}") || !appID.matches("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")) throw new Exception("Invalid capture request");
            ui = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo info = ui.getServiceInfo();
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            ui.setServiceInfo(info);
            waitForApp();
            JSONObject state=recipe.optJSONObject("testState");
            if(state!=null) { runSteps(state.getJSONArray("preparation")); waitFor(state.getString("readySelector")); }
            if(state!=null && recipe.has("deeplink") && !recipe.isNull("deeplink")) {
                android.content.Intent link=new android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse(recipe.getString("deeplink")));
                link.setPackage(appID);link.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(link);waitForApp();
            }
            if ("true".equals(arguments.getString("recording"))) {
                if("true".equals(arguments.getString("live"))) {
                    runSteps(recipe.getJSONArray("steps")); live(runID);
                } else record(runID);
                result.putString("wfResult", "ok"); finish(-1, result); return;
            }
            runSteps(recipe.getJSONArray("steps"));
            root(); // Never accept a screenshot after an action navigates away from the selected app.
            Bitmap screen = ui.takeScreenshot();
            if (screen == null) throw new Exception("Screenshot unavailable; check app screenshot protection");
            File output = new File(getContext().getFilesDir(), "capture-" + runID + ".png");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                if (!screen.compress(Bitmap.CompressFormat.PNG, 100, stream)) throw new Exception("PNG encoding failed");
            }
            screen.recycle();
            result.putString("wfResult", "ok");
            finish(-1, result);
        } catch (Exception error) {
            result.putString("wfError", error.getMessage() == null ? "Screen flow failed" : error.getMessage());
            finish(0, result);
        }
    }
    private AccessibilityNodeInfo root() throws Exception {
        if (android.os.Build.VERSION.SDK_INT>=34) ui.clearCache();
        AccessibilityNodeInfo root = ui.getRootInActiveWindow();
        int layer=Integer.MIN_VALUE;
        for(android.view.accessibility.AccessibilityWindowInfo window:ui.getWindows()) {
            if(window.getType()==android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD)continue;
            AccessibilityNodeInfo candidate=window.getRoot();if(candidate==null)continue;
            boolean ours=appID.contentEquals(candidate.getPackageName()==null?"":candidate.getPackageName());
            if((window.isActive()||window.isFocused())&&!ours)
                throw new Exception("The selected app is not in the foreground. Dismiss system dialogs first");
            if(ours&&candidate.isVisibleToUser()&&window.getLayer()>layer) {root=candidate;layer=window.getLayer();}
        }
        if(root!=null)root.refresh();
        if (root == null || !appID.contentEquals(root.getPackageName() == null ? "" : root.getPackageName()))
            throw new Exception("The selected app is not in the foreground. Dismiss system dialogs first (active: " + (root == null ? "unavailable" : root.getPackageName()) + ")");
        return root;
    }
    private boolean supportsText(AccessibilityNodeInfo node) {
        if (node == null || !node.isVisibleToUser()) return false;
        for (AccessibilityNodeInfo.AccessibilityAction action : node.getActionList())
            if (action.getId() == AccessibilityNodeInfo.ACTION_SET_TEXT) return true;
        return false;
    }
    private void collectInputs(AccessibilityNodeInfo node, ArrayList<AccessibilityNodeInfo> fields, int depth) {
        if (node == null || depth > 100) return;
        if (supportsText(node)) fields.add(node);
        for (int i=0;i<node.getChildCount();i++) collectInputs(node.getChild(i),fields,depth+1);
    }
    private AccessibilityNodeInfo textTarget() throws Exception {
        long end = SystemClock.uptimeMillis()+3000;
        while (SystemClock.uptimeMillis()<end) {
            AccessibilityNodeInfo root = root();
            AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (supportsText(focused)) return focused;
            ArrayList<AccessibilityNodeInfo> fields = new ArrayList<>();
            collectInputs(root,fields,0);
            ArrayList<AccessibilityNodeInfo> selected = new ArrayList<>();
            for (AccessibilityNodeInfo field:fields) if (field.isFocused()) selected.add(field);
            if (selected.size()==1) return selected.get(0);
            // Compose may omit input focus from its virtual accessibility tree.
            // A single visible set-text target is unambiguous; never choose among multiple fields.
            if (fields.size()==1) return fields.get(0);
            SystemClock.sleep(200);
        }
        throw new Exception("Tap a specific editable input before Type text (no unique input target)");
    }
    private void waitForApp() throws Exception {
        long end = SystemClock.uptimeMillis()+10000;
        while (SystemClock.uptimeMillis()<end) {
            try { root(); return; } catch (Exception e) { SystemClock.sleep(200); }
        }
        root();
    }
    private void runSteps(JSONArray steps) throws Exception {
            if (steps.length() > 30) throw new Exception("Too many actions");
            for (int i = 0; i < steps.length(); i++) {
                JSONObject step = steps.getJSONObject(i);
                String action = step.getString("action"), value = step.getString("value");
                if (action.equals("tap") || action.equals("wait")) {
                    ArrayList<AccessibilityNodeInfo> matches = waitFor(value);
                    if (action.equals("tap")) {
                        if (matches.size() != 1) throw new Exception("Use a unique label or resource id: " + value);
                        Rect bounds = new Rect(); matches.get(0).getBoundsInScreen(bounds);
                        touch(bounds.centerX(), bounds.centerY(), bounds.centerX(), bounds.centerY(), 60);
                    }
                } else if (action.equals("type")) {
                    AccessibilityNodeInfo focused = textTarget();
                    Bundle text = new Bundle(); text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
                    if (!focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text)) throw new Exception("This input does not support native text entry");
                } else if (action.equals("swipeUp") || action.equals("swipeDown")) {
                    Bitmap screen = ui.takeScreenshot();
                    if (screen == null) throw new Exception("Unable to capture display size");
                    int x = screen.getWidth()/2, top = screen.getHeight()/4, bottom = screen.getHeight()*3/4;
                    screen.recycle();
                    touch(x, action.equals("swipeUp") ? bottom : top, x, action.equals("swipeUp") ? top : bottom, 400);
                } else throw new Exception("Unsupported action: " + action);
                SystemClock.sleep(250);
            }
    }

    private ArrayList<AccessibilityNodeInfo> waitFor(String value) throws Exception {
        long end = SystemClock.uptimeMillis()+10000;
        while (SystemClock.uptimeMillis()<end) {
            ArrayList<AccessibilityNodeInfo> found = new ArrayList<>();
            try { collect(root(), value, found, new HashSet<String>(), 0); }
            catch (Exception transition) { SystemClock.sleep(200); continue; }
            if (!found.isEmpty()) return found;
            SystemClock.sleep(200);
        }
        throw new Exception("Visible element not found: " + value);
    }
    private void collect(AccessibilityNodeInfo node, String value, ArrayList<AccessibilityNodeInfo> matches, HashSet<String> boundsSeen, int depth) {
        if (node == null || depth > 100) return;
        if (node.isVisibleToUser() && (value.contentEquals(node.getText()==null ? "" : node.getText()) ||
            value.contentEquals(node.getContentDescription()==null ? "" : node.getContentDescription()) ||
            value.contentEquals(node.getHintText()==null ? "" : node.getHintText()) || value.equals(node.getViewIdResourceName()))) {
            Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
            if (!bounds.isEmpty() && boundsSeen.add(bounds.toShortString())) matches.add(node);
        }
        for (int i=0;i<node.getChildCount();i++) collect(node.getChild(i),value,matches,boundsSeen,depth+1);
    }
    private void touch(int x, int y, int endX, int endY, int duration) throws Exception {
        long start = SystemClock.uptimeMillis();
        inject(start,start,MotionEvent.ACTION_DOWN,x,y);
        for (int t=16;t<duration;t+=16) {
            SystemClock.sleep(16);
            inject(start,SystemClock.uptimeMillis(),MotionEvent.ACTION_MOVE,x+(endX-x)*(float)t/duration,y+(endY-y)*(float)t/duration);
        }
        inject(start,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,endX,endY);
    }
    private String string(CharSequence value) { return value == null ? "" : value.toString(); }
    private static final class RecordedNode {
        Rect bounds; String[] candidates; String label; boolean enabled,editable,secure,recordable;
    }
    private void recordingTree(AccessibilityNodeInfo node, ArrayList<RecordedNode> items, int depth) {
        if (node==null || depth>80 || items.size()>=1000) return;
        if (node.isVisibleToUser()) {
            RecordedNode item=new RecordedNode();item.bounds=new Rect();node.getBoundsInScreen(item.bounds);
            item.secure=node.isPassword();item.enabled=node.isEnabled();item.editable=supportsText(node);
            String text=item.secure?"":string(node.getText()),description=string(node.getContentDescription()),hint=string(node.getHintText());
            item.label=!text.isEmpty()?text:(!description.isEmpty()?description:hint);
            item.recordable=node.isClickable()||item.editable||!text.isEmpty()||!hint.isEmpty();
            item.candidates=new String[]{string(node.getViewIdResourceName()),description,hint,text};
            if(!item.bounds.isEmpty())items.add(item);
        }
        for(int i=0;i<node.getChildCount();i++)recordingTree(node.getChild(i),items,depth+1);
    }
    private void recordNodes(AccessibilityNodeInfo root, JSONArray nodes, int width, int height, int depth) throws Exception {
        // Read the accessibility tree once per frame. Re-querying it for every
        // candidate makes large Compose screens quadratic and delays every tap.
        ArrayList<RecordedNode> items=new ArrayList<>();recordingTree(root,items,0);
        java.util.HashMap<String,HashSet<String>> matches=new java.util.HashMap<>();
        for(RecordedNode item:items)for(String candidate:item.candidates) {
            if(candidate.trim().isEmpty()||candidate.getBytes("UTF-8").length>4096)continue;
            HashSet<String> bounds=matches.get(candidate);if(bounds==null){bounds=new HashSet<>();matches.put(candidate,bounds);}
            bounds.add(item.bounds.toShortString());
        }
        for(RecordedNode item:items) {
            Rect bounds=new Rect(item.bounds);if(!item.enabled||!item.recordable||!bounds.intersect(0,0,width,height))continue;
            String selector="";
            for(String candidate:item.candidates)if(matches.containsKey(candidate)&&matches.get(candidate).size()==1){selector=candidate;break;}
            if(selector.isEmpty())continue;
            String display=item.label.isEmpty()?selector:item.label;if(display.length()>500)display=display.substring(0,500);
            JSONObject entry=new JSONObject();entry.put("selector",selector);entry.put("label",display);
            entry.put("x",bounds.left/(double)width);entry.put("y",bounds.top/(double)height);
            entry.put("w",bounds.width()/(double)width);entry.put("h",bounds.height()/(double)height);
            entry.put("editable",item.editable);entry.put("secure",item.secure);nodes.put(entry);
        }
    }
    private void atomic(File destination, byte[] value) throws Exception {
        File temp = new File(destination.getPath()+".tmp");
        try (FileOutputStream stream = new FileOutputStream(temp)) { stream.write(value); }
        if (!temp.renameTo(destination)) throw new Exception("Unable to save recording response");
    }
    private JSONArray recordingReply(File directory,String id,String action,String value,String error) throws Exception {
        try { ui.waitForIdle(200,3000); } catch (java.util.concurrent.TimeoutException animation) { }
        Bitmap screen=null;JSONArray nodes=null;long deadline=SystemClock.uptimeMillis()+5000;
        do {
            AccessibilityNodeInfo active=root();screen=ui.takeScreenshot();
            if(screen==null)throw new Exception("Screenshot unavailable; check app screenshot protection");
            nodes=new JSONArray();recordNodes(active,nodes,screen.getWidth(),screen.getHeight(),0);
            if(nodes.length()>0||SystemClock.uptimeMillis()>=deadline)break;
            screen.recycle();screen=null;SystemClock.sleep(200);
        }while(true);
        try {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            if (!screen.compress(Bitmap.CompressFormat.PNG,100,bytes)) throw new Exception("PNG encoding failed");
            atomic(new File(directory,"screen.png"),bytes.toByteArray());
        } finally { screen.recycle(); }
        JSONObject reply = new JSONObject();reply.put("id",id);reply.put("nodes",nodes);
        if(action!=null) reply.put("action",action);if(value!=null)reply.put("value",value);if(error!=null)reply.put("error",error);
        atomic(new File(directory,"reply.json"),reply.toString().getBytes("UTF-8"));return nodes;
    }
    private void live(String runID) throws Exception {
        File directory=new File(getContext().getFilesDir(),"recording-"+runID);
        if(!directory.mkdirs()&&!directory.isDirectory())throw new Exception("Unable to start live preview");
        File fifo=new File(directory,"frames");
        android.system.Os.mkfifo(fifo.getPath(),0600);
        recordingReply(directory,"ready",null,null,null);
        long end=SystemClock.uptimeMillis()+900000;
        try(java.io.DataOutputStream output=new java.io.DataOutputStream(new FileOutputStream(fifo))) {
            while(SystemClock.uptimeMillis()<end) {
                // Activity recreation (for example a theme change) can briefly remove its window.
                // Wait without capturing anything until this same app is visible again.
                waitForApp();
                Bitmap screen=ui.takeScreenshot();
                if(screen==null)throw new Exception("Live screenshot unavailable");
                java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream();
                try {
                    root(); // Discard the image if focus changed while takeScreenshot was running.
                    if(!screen.compress(Bitmap.CompressFormat.PNG,100,bytes))throw new Exception("Live PNG encoding failed");
                }
                finally { screen.recycle(); }
                byte[] png=bytes.toByteArray();
                if(png.length==0||png.length>8*1024*1024)throw new Exception("Live frame exceeds 8 MiB");
                output.writeInt(png.length);output.write(png);output.flush();SystemClock.sleep(250);
            }
        } finally { fifo.delete(); }
    }
    private void record(String runID) throws Exception {
        File directory = new File(getContext().getFilesDir(),"recording-"+runID);
        if (!directory.mkdirs() && !directory.isDirectory()) throw new Exception("Unable to start recording");
        File commandFile = new File(directory,"command.json");
        JSONArray nodes = recordingReply(directory,"ready",null,null,null);
        long end = SystemClock.uptimeMillis()+900000;int count=0;
        try {
            while (SystemClock.uptimeMillis()<end) {
                if(!commandFile.isFile()){SystemClock.sleep(100);continue;}
                if(commandFile.length()>32000)throw new Exception("Invalid recording command");
                JSONObject command = new JSONObject(new String(java.nio.file.Files.readAllBytes(commandFile.toPath()),"UTF-8"));
                commandFile.delete();String id=command.getString("id"),action=command.getString("action");
                if(!id.matches("[A-Fa-f0-9-]{36}"))throw new Exception("Invalid recording command id");
                if(action.equals("stop"))return;
                String value=null,error=null;
                try {
                    root();if(!action.equals("refresh") && count>=30)throw new Exception("Recording limit reached (30 actions)");
                    if(action.equals("tap")) {
                        double x=command.getDouble("x"),y=command.getDouble("y");
                        if(!Double.isFinite(x)||!Double.isFinite(y)||x<0||x>1||y<0||y>1)throw new Exception("Tap inside the app screen");
                        JSONObject chosen=null;double area=Double.MAX_VALUE;
                        for(int i=0;i<nodes.length();i++) {JSONObject n=nodes.getJSONObject(i);double a=n.getDouble("w")*n.getDouble("h");
                            if(x>=n.getDouble("x")&&x<=n.getDouble("x")+n.getDouble("w")&&y>=n.getDouble("y")&&y<=n.getDouble("y")+n.getDouble("h")&&a<area){chosen=n;area=a;}}
                        if(chosen==null)throw new Exception("This control needs a unique accessibility label before it can be recorded");
                        value=chosen.getString("selector");ArrayList<AccessibilityNodeInfo> matches=waitFor(value);
                        if(matches.size()!=1)throw new Exception("The control changed. Refresh the preview and try again");
                        Rect b=new Rect();matches.get(0).getBoundsInScreen(b);touch(b.centerX(),b.centerY(),b.centerX(),b.centerY(),60);
                    } else if(action.equals("type")) {
                        AccessibilityNodeInfo field=textTarget();if(field.isPassword())throw new Exception("Password entry is not recorded");
                        value=command.getString("value");if(value.isEmpty()||value.length()>2000)throw new Exception("Enter 1–2000 characters");
                        Bundle text=new Bundle();text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,value);
                        if(!field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,text))throw new Exception("This input does not support native text entry");
                    } else if(action.equals("swipeUp")||action.equals("swipeDown")) {
                        Bitmap screen=ui.takeScreenshot();if(screen==null)throw new Exception("Screenshot unavailable");
                        int x=screen.getWidth()/2,top=screen.getHeight()/4,bottom=screen.getHeight()*3/4;screen.recycle();
                        touch(x,action.equals("swipeUp")?bottom:top,x,action.equals("swipeUp")?top:bottom,400);
                    } else if(!action.equals("refresh"))throw new Exception("Unsupported recording action");
                    if(!action.equals("refresh"))count++;SystemClock.sleep(250);
                } catch(Exception e){error=e.getMessage();}
                nodes=recordingReply(directory,id,error==null&&!action.equals("refresh")?action:null,value,error);
            }
            throw new Exception("Recording ended after 15 minutes. Start a new recording");
        } finally {File[] files=directory.listFiles();if(files!=null)for(File f:files)f.delete();directory.delete();}
    }
    private void inject(long start,long time,int action,float x,float y) throws Exception {
        MotionEvent event=MotionEvent.obtain(start,time,action,x,y,0);
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try { if (!ui.injectInputEvent(event,true)) throw new Exception("Input injection failed"); }
        finally { event.recycle(); }
    }
}
