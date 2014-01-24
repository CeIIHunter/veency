
### This is a VNC server for iPhones, iPod touch, iPad, etc.
* You should install this on your device in case the digitizer screen is broken.  It enables you to access the device without a working screen.



### To install...
* Copy the .deb file to the device and run "dpkg -i veency....deb"
* Power the device off and back on.  (Not powering off and only restarting springboard may leave behind stray veency servers)

### To use...
* The default screen on retina devices is too big for VNC, it'll be very slow.  Go to settings and change divide screen size to "3" or higher if you don't mind losing quality.
* http://www.realvnc.com/  RealVNC viewer is free.
* Or on linux use "vncviewer -encodings tight quality 5 <IPOfDevice>"


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



