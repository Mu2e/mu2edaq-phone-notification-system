# Overview

This is a iphone application that can recieve push notifications from the Mu2e DAQ system.  The events will come from different applications within the mu2e DAQ systems and will be propagated and filtered through a server application running in the DAQ environment.

Users will be able to recieve notifications even if they are not on the mu2e DAQ network.

# Description

The notifications that it will recieves are primarily error and warning events.

The application should display these events along with the information about them.

There should be a dashboard view of errors and warnings that have been issued that the user can go through.

There should be a splash screen that comes up when the application is loaded.

There should be a bearer token based authentication system for registering a device with the central server that is pushing out the notifications.

There needs to be a server setup that run on the Mu2e data acquistion system network that can recieve messages from different applications and then will filter and send the push notifications out.

Configuration should all be via yaml.

There should be a simple library for publishing events to the server.  This can be the same as or a modification/refactoring of an existing messaging scheme within the mu2e DAQ.  The library should provide both a c++ and python callable API.

The server should have a web based interface which allows you to see notifications and configure filters and destinations for notifications.

The server and the client library for publishing events should support the auto discovery protocal of the rest of the DAQ system.

The server should be able to send an auto configuration to a phone to do the registeration and setup.  It should also support configuration through the web browser using a QR code.

There should also be integration which sends notifications to the SLACK application.

There should also be integration which sends notification to the Discord application.

All user interfaces should be modern.

The web applications should support fermilab SSO (oidc) 

# Testing

There should be tests for all parts of the project. Use the most appropriate test suites for each component.