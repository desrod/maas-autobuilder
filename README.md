# MAAS Auto-builder

	This is a quick-and-dirty set of shell scripts that will build out
	and bootstrap a MAAS environment with all of the bits and pieces you
	need to get it running for any cloud, any workload.

	manage-maas-nodes...: Create kvm instances that MAAS will manage
	bootstrap--maas.sh..: Build and bootstrap your MAAS environment

	There are plenty of options to customize its behavior, as well as
	drop in to any step of the process without rebuilding the full MAAS
	from scratch.


## Requirements

	Requires, minimally, 'bash', 'jq' and a working Ubuntu environment. 
	This has **not** been tested on CentOS or Debian, but should work
	minimally on those environments, if you choose to make that your
	host.  Patches are welcome, of course.


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

	Just run './bootstrap-maas.sh' with the appropriate option above. 
	Minimally, you'll want to use './bootstra-maas.sh -b' or '-i' to
	install just the components needed.

	I've done all the work needed to make this as idempotent as
	possible.  It will need some minor tweaks to get working with MAAS
	2.4.x, becauase of the newer PostgreSQL dependencies.

	MAAS from snap is also not supported (yet) again for the same SQL
	dependencies which are included inside the MAAS snap.


## TODO and What's Next

   * Support for using MAAS from snap vs.  main or PPA.  With snap,
     postgresql and other deps are installed in the snap, so handling has to
     change

