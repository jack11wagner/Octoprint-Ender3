# Octoprint-Ender3

## Requirements:
    - Raspberry Pi
    - Ethernet cable (wifi setup is possible but you at least need to use ethernet initially)
    -   Micro or mini USB cable (depending on what model of ender)
    - 2x Ender 3 printers - don’t plug in the printers yet
    - 2x 1080p cameras (optional) - don’t plug in the cameras yet
    - Micro SD card and Mac adapter

## Setup 
### Octopi Image
1. Download and install the Raspberry Pi Imager [Raspberry Pi Foundation](https://www.raspberrypi.org/software/).
2. Insert your SD card into your Macbook
3. Open the Raspberry Pi Imager and click on "Choose OS"
4. Then go to “Other specific purpose OS > OctoPi”. There should be the latest version.
5. Back on the main window, click "Choose Storage" and select your SD card
6. Click the Gear Icon if you want to customize any of the Image Settings
	- I reccomend ennabling ssh and setting the hostname to a recognizable name, otherwise the default will be octopi.local
7. After customizing settings, return to the home screen and click “Write”
8. The Raspberry Pi Imager will download and install the OctoPrint image (this will take a few minutes to finish writing)
9. Eject the microsd card from your device
10. Insert the newly imaged Octoprint SD card into the Raspberry Pi

### Creating Multiple Octoprint Instances on a Raspberry Pi
<mark>TODO</mark>
