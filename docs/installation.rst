
.. _installation:

Installation
============

Conjure can be installed either by downloading a binary distribution, or by compiling it from source code.

Downloading a binary
--------------------

Conjure is available as an executable binary for Linux and MacOS.
If it is available for your platform, you can just `download it <https://www.github.com/conjure-cp/conjure/releases/latest>`_ and run it.
It may be useful to save the binary under a directory that is in your search PATH, so you do not have to type the full path to the Conjure executable to run it.

For Windows, please use the Linux binaries with the
`Windows Subsystem for Linux <https://en.wikipedia.org/wiki/Windows_Subsystem_for_Linux>`_.


Compiling from source
---------------------

In order to compile Conjure on your computer, please download the source code from `GitHub <https://github.com/conjure-cp/conjure>`_.

.. code-block:: bash

    git clone git@github.com:conjure-cp/conjure.git
    cd conjure
    BIN_DIR=/somewhere/in/your/path make install

Conjure is implemented in Haskell, it can be compiled using either `cabal-install <http://wiki.haskell.org/Cabal-Install>`_ or `stack <https://docs.haskellstack.org/en/stable/README/>`_.

It comes with a Makefile which will use Stack by default.
The default target in the Makefile will install Stack using the standard procedures (which involves downloading and running a script).
For more precise control, you might want to consider installing the Haskell tools beforehand instead of using the Makefile.

In addition, a number of supported backend solvers can be compiled using the `make solvers` target.
This target also takes a BIN_DIR environment variable to control the location of the solver executables,
and a PROCESSES environment variable to control how many processes to use when building solvers

.. code-block:: bash

    BIN_DIR=/somewhere/in/your/path PROCESSES=4 make solvers

Installing Savile Row
---------------------

Since Conjure works by generating an Essence' model, Savile Row is a vital tool when using it.
You do not need to download Savile Row separately when you compile Conjure from source.
An up-to-date version of Savile Row is also copied next to the Conjure executable.

A standalone version of Savile Row and user documentation for Savile Row can be downloaded from `its website <http://savilerow.cs.st-andrews.ac.uk>`_.

