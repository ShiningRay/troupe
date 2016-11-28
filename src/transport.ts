/// <reference path="../node_modules/@types/ioredis/index.d.ts" />

import { Duplex, Transform } from 'stream'

import { Message } from './messages'
import { Stage } from './stage';

export interface Transport extends NodeJS.ReadWriteStream{
    write(obj:any)
}

/**
 * TODO: implements some error handle mechenism, like reconnect
 */
export abstract class AbstractTransport extends Duplex implements Transport {
    
    constructor(protected stage: Stage, protected encoder = JSON.stringify, protected decoder = JSON.parse) {
        super({ objectMode: true });
    }

    abstract _read(size?) 
    abstract _write(obj, enc, next) 
}

