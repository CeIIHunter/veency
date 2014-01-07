
### This is a version of veency that compiles on OSX
* It also has a fix for broken images on OpenGLES apps.

### To compile...
* git clone https://github.com/DHowett/theos.git
* git clone https://github.com/iolate/SimulateTouch.git
* "unzip theos_includes.zip" into theos/include  (or you can grab the headers from various places, iphone-dev, etc.)
* Edit Makefile.osx,  change the framework path to where you have Xcode installed.
* make -f Makefile.osx

### To install...
* Copy the "Veency.dylib" file to this folder on your mobile:  /Library/MobileSubstrate/DynamicLibraries/
* Restart springboard on the device or power the device off and back on.

