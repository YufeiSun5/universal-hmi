import os
import pathlib
import shutil
import tarfile
root=pathlib.Path.cwd()
web=root/"dist/web"
linux=root/"dist/linux"
windows=root/"dist/windows"
for folder in [linux,windows]:
 shutil.copytree(web,folder/"web",dirs_exist_ok=True)
output=root/"dist/final";output.mkdir(parents=True,exist_ok=True)
for name in ["universal_hmi","universal-hmi-server"]:
 (linux/name).chmod(0o755)
with tarfile.open(output/"universal-hmi-linux-x64.tar.gz","w:gz") as archive:
 archive.add(linux,arcname="universal-hmi")
