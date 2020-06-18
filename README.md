# INDEGO - FHEM Module

## Used branching model
* Master branch: Production version
* Dev branch: Latest development version

## Community support
The FHEM Forum is available [here](https://forum.fhem.de/) for general support.
In case you have a specific question about this module, it is recommended to find the right sub-forum.
It can either be found from the module info card using the FHEM Installer (e.g. using command `search <MODULE_NAME>`) or it can be determined from the [MAINTAINER.txt](https://github.com/fhem/fhem-mirror/blob/master/fhem/MAINTAINER.txt) file.

## Bug reports and feature requests
Identified bugs and feature requests are tracked using [Github Issues](https://github.com/fhem/INDEGO/issues).

## Pull requests / How to participate into development
You are invited to send pull requests to the dev branch whenever you think you can contribute with some useful improvements to the module. The module maintainer will review you code and decide whether it is going to be part of the module in a future release.

## Install / Update FHEM module directly from Git repository

Load the modules into FHEM:

* from Master branch

        update all https://raw.githubusercontent.com/fhem/INDEGO/master/controls_INDEGO.txt
* from Dev branch

        update all https://raw.githubusercontent.com/fhem/INDEGO/dev/controls_INDEGO.txt

Restart FHEM:
    
    shutdown restart