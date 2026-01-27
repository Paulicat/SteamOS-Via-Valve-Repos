I initially created this to do an "arch type" native (mutable) installation of SteamOS on my old OneXPlayer 2.
At the time, I couldn't easily install official immutable steamos via the recovery so I logged a list 
of commands that installed SteamOS via the Valve SteamOS official repos for a traditional mutable installation.
I've since sold the OneXPlayer and repurposed the instruction set for the Steamdeck.
Why? I dunno, I like the control and I like having a mutable installation.
With some bash scripting, I converted the manual commands to a bash installer script that just needs a few prompts
to get a fully working mutable SteamOS installation.
Get 2 drives, one with the archlinux installation iso, and a second to bring the script in.
Boot the latest archlinux iso and once booted, mount your second drive somewhere and run the install-steamos.sh 
from your mount point.
It will prompt for wifi and a few various things like username (use deck for best compatibility with decky-loader)
and the drive you want to install to (nvme0n1 for the internal drive).
Currently it handles 3.6 and 3.7 and I'll extend as 3.8 becomes official.
For whatever the "current" release version is (3.7 as of this time), doing a pacman -Syu after installation will 
install any upgraded packages from the official repos. This will let you stay current with current release branch
until they 'freeze' the repos (when they move on to the next version).
No, it does not allow you to upgrade from 3.x to the next 3.x and I doubt I'll put the effort into that.
Chances are good no one is going to use this besides me anyways. :-D
