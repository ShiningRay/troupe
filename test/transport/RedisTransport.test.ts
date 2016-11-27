import * as sinon from 'sinon';
import { Transport } from '../../src/transport';
import { NullTransport } from '../../src/transport/null';
import { Stage } from '../../src/stage';
import { expect } from 'chai';
import rewire = require('rewire')
import { RedisTransport } from '../../src/transport/redis';
import { MessageType } from '../../src/messages';
import mm = require('mm')

describe('RedisTransport', () => {
    var transport
    beforeEach(() => {

    })
    describe('receive objects', () => {
        const msg = {
            type: MessageType.invocation,
            from: 'test1',
            to: 'test',
            method: 'test',
            reqid: 1,
            params: [111]
        };
        const msg2 = {
            type: MessageType.result,
            from: 'test',
            to: 'test1',
            reqid: 1,
            result: 'world'
        }
        beforeEach(() => {
            
            mm(Stage.current, 'id', 'test');
            transport = new RedisTransport(Stage.current);
            
            // mm(transport, 'mailbox', redis);
        });
        afterEach((done) => {
            transport.on('finish', () => done())
            transport.emitter.flushdb().then(() => transport.end())
            mm.restore();
        })
        it('receives objects from queue', (done) => {
            transport.emitter.rpush('mailbox:test', JSON.stringify(msg)).catch(console.error)
            transport.once('data', (data) => {
                expect(data).deep.eq(msg);
                transport.emitter.rpush('mailbox:test', JSON.stringify(msg2))
                transport.once('data', (data) => {
                    expect(data).deep.eq(msg2);
                    done();
                })
            })
        });

        it('never timeouts', function (done) {
            this.timeout(20000);
            transport.once('data', (data) => {
                expect(data).deep.eq(msg);
                done();
            })
            setTimeout(() => 
                transport.emitter.rpush('mailbox:test', JSON.stringify(msg)).catch(console.error),
                15000);
        });
    });

    // it('receive object', (done) => {
    //     transport.write({ test: 'test' })
    //     transport.on('data', (data) => {
    //         expect(data).to.be.a('object')
    //         expect(data.test).to.eql('test')
    //         done()
    //     })
    // });

});