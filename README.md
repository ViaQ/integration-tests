# integration-tests
[![Travis CI](https://secure.travis-ci.org/ViaQ/integration-tests.png)](http://travis-ci.org/#!/ViaQ/integration-tests)

Travis CI runs this test:

    $ ./openshift-test.sh

The rest of this is legacy information.

*This is work in progress.*

## Jenkins deployment.

+ We have jenkins deployed at https://209.132.179.155/ (with self-signed certificate)
+ Use github accounts to authenticate to jenkins.
+ Ask isimluk to get extra permissions.
+ Jenkins [deployment](jenkins/deployment.md) and [needed maitenance](jenkins/maintenance.md) are well documented.
+ Each slave system is configured with the following two accounts:
  + jenkins - User that runs the tests/jobs on the slave
  + cloud-user - for debugging, this user can run sudo
+ How to connect by SSH to slave?
  + connect to master: `ssh cloud-user@209.132.179.155`
  + connect to slave from master: `ssh fedora23.slave`

## Test Prerequisites

```
 dnf install docker atomic
 service docker start
```

## Test Run

```
 ./run.sh
```
