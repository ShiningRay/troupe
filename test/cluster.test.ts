import * as core from '../src/core'
import * as cluster from '../src/cluster'
import {fork} from 'child_process'

core.bootstrap();

fork('./dummy');

describe('cluster', function(){
    describe('world', function(){
        
    })
})