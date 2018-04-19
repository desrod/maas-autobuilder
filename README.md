# MAAS Auto-builder


## Requirements


## Components

```
  -a <cloud_name>    Do EVERYTHING (maas, juju cloud, juju bootstrap)
  -b                 Build out and bootstrap a new MAAS
  -c <cloud_name>    Add a new cloud + credentials
  -i                 Just install the dependencies and exit
  -j <name>          Bootstrap the Juju controller called <name>
  -n                 Create MAAS kvm nodes (to be imported into chassis)
  -r                 Remove the entire MAAS server + dependencies
  -t <cloud_name>    Tear down the cloud named <cloud_name>
```

## Installing and testing MAAS 


## TODO and What's Next

   * Support for using MAAS from snap vs. main or PPA. With snap, postgresql
     and other deps are installed in the snap, so handling has to change
