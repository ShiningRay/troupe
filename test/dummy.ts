import * as core from '../src/core';
import * as cluster from '../src/cluster';
import {BasicActor} from '../src/rpc'
import * as Promise from 'bluebird'

class DummyActor extends BasicActor {
    hello(){
        return 'world'
    }
    
    asyncHello(){
        return new Promise((resolve) => setTimeout(() => resolve('world'), 2000));
    }
}

core.bootstrap()