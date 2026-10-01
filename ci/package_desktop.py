import pathlib
import shutil
import sys
root=pathlib.Path.cwd().parent
target=sys.argv[1]
bundle=root/("app/build/linux/x64/release/bundle" if target=="linux" else "app/build/windows/x64/runner/Release")
server=root/"dist"/("universal-hmi-server" if target=="linux" else "universal-hmi-server.exe")
shutil.copy2(server,bundle/server.name)
if target=="linux":
 (bundle/server.name).chmod(0o755)
(bundle/"README.txt").write_text("Universal HMI 0.1\nStart universal_hmi (or universal_hmi.exe).\nThe bundled Go backend starts automatically on 127.0.0.1:18080.\nData: Linux $XDG_DATA_HOME/universal-hmi, Windows %LOCALAPPDATA%/universal-hmi.\nUse the simulated project to review the workflow; production sources require explicit connect.\n",encoding="utf-8")
