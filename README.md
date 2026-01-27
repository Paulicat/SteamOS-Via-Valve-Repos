I initially created this to do an "arch type" native (mutable) installation of SteamOS on my old OneXPlayer 2.
At the time, I couldn't easily install official immutable steamos via the recovery so I logged a list 
of commands that installed SteamOS via the Valve SteamOS official repos for a traditional mutable installation.
I've since sold the OneXPlayer and repurposed the instruction set for the Steamdeck.
Why? I dunno, I like control and I like having a mutable installation.
With some bash scripting, I converted the manual istructions to a bash installer script that just needs a few prompts
to get a fully working mutable SteamOS installation.
Currently it handles 3.6 and 3.7 and I'll extend as 3.8 becomes official.
For whatever the "current" release version is (3.7 as of this time), doing a pacman -Syu after installation will 
install any upgraded packages from the official repos. This will let you stay current with current release branch
until they 'freeze' the repos (when they move on to the next version).
No, it does not allow you to upgrade from 3.x to the next 3.x and I doubt I'll put the effort into that.
Chances are good no one is going to use this besides me anyways. :-D
