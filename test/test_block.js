'use strict';
let _ = require('underscore');
let chai = require('chai');
let expect = chai.expect;


let macAddress = "02:42:AC:11:00:02";
let destination = "159.153.186.70";

let b = require('../net2/Block.js');

b.blockOutgoing(macAddress, destination, (err) => {
  
});

setTimeout(function() { process.exit(0) }, 30000);
