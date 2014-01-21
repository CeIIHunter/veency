

### This is a version of veency that compiles on OSX
* Adds a "Skip black screens" option to enable VNC to work with Camera, OpenGLES apps.
* Adds a divide screen size feature to speed things up, especially on retina devices.
* Uses SimulateTouch.

### To compile...
* git clone https://github.com/DHowett/theos.git
* git clone https://github.com/iolate/SimulateTouch.git
* "unzip theos_includes.zip" into theos/include  (or you can grab the headers from various places, iphone-dev, etc.)
* Edit Makefile.osx,  change the framework path to where you have Xcode installed.
* make -f Makefile.osx package

### To install...
* Copy the .deb file to the device and run "dpkg -i veency....deb"
* Power the device off and back on.  (Not powering off and only restarting springboard may leave behind stray veency servers)

### To use...
* Don't know why but it has stopped working with "remmina"
* Use "vncviewer -encodings tight quality 5 <IPOfDevice>"

