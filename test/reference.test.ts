import rewire = require('rewire')
import * as sinon from 'sinon'
import {assert, expect} from 'chai'
// var appeareance = rewire("../src/myModule.js")
// appeareance.__set__('Scenario', sinon)
import {Reference} from '../src/reference'
import {Scenario} from '../src/scenario'
import mm = require('mm')
import {MessageType} from '../src/messages'
import { EventEmitter } from 'events';

class MyReference extends Reference {
    hello(world:string){
        return this.$invoke('hello', [world]);
    }
}

describe('Reference', () => {
    
    beforeEach(() => {
        // this.mock = sinon.mock(Scenario).expects('sendMessage')
    })

    afterEach(() => {
        // this.mock.restore();
    })

    describe('#sends message', () => {
        it('resolve result', (done) => {
            var called;
            var ref = new MyReference();
            mm(Scenario, 'sendMessage', (m) => {
                expect(m.reqid).to.be.a('number')
                expect(m.type).to.eql(MessageType.invocation)
                expect(m.method).to.eql('hello')
                expect(m.params).to.eql(['test'])
                setImmediate(() => ref.$handleResult({
                    type: MessageType.result,
                    reqid: m.reqid,
                    to: ref.$id,
                    from: '',
                    result: 'TEST'
                }));
            });
            
            var p = ref.hello('test');
            expect(p.then).to.be.a('function');
            p.then((v) => {
                expect(v).to.eql('TEST')
                done();
            })
            mm.restore();
        });
        it('handles error', (done) => {
            var called;
            var ref = new MyReference();
            mm(Scenario, 'sendMessage', (m) => {
                expect(m.reqid).to.be.a('number')
                expect(m.type).to.eql(MessageType.invocation)
                expect(m.method).to.eql('hello')
                expect(m.params).to.eql(['test'])
                setImmediate(() => ref.$handleError({
                    type: MessageType.error,
                    reqid: m.reqid,
                    to: ref.$id,
                    from: '',
                    name: 'TestError',
                    message: 'Test Error',
                    stack: ''
                }));
            });
            
            var p = ref.hello('test');
            expect(p.catch).to.be.a('function');
            p.catch((err) => {
                expect(err.name).to.eql('TestError')
                expect(err.message).to.eql('Test Error')
                done();
            })
            mm.restore();            
        });
    });

    describe('$handleResult', () => {
        var message, emitter:EventEmitter, ref;
        beforeEach(() => {
            emitter = new EventEmitter();
            mm(Scenario, 'sendMessage', function(msg){
                message = msg;
                emitter.emit('message', msg);
            })
            ref = new MyReference();
        })

        afterEach(() => {
            mm.restore();
        })            
         
        it('resolves result', (done) => {
            emitter.on('message', function(msg){
                setImmediate(() => ref.$handleResult({
                    from: msg.to,
                    to: msg.from,
                    type: MessageType.result,
                    reqid: msg.reqid,
                    result: 'world'
                }));
            });

            ref.hello('world').then((res) => {
                expect(res).to.eq('world')
                done()
            });
        });
    });

    describe('$handleEvent', () => {
        beforeEach(() => {
            this.ref = new MyReference();
        })
        it('emit events', (done) => {
            this.ref.on('Test', (data) => {
                expect(data).to.eq('Hello, World')
                done();
            })
            this.ref.$handleEvent({
                type: MessageType.event,
                from: 'test',
                to: 'test2',
                name: 'Test',
                data: 'Hello, World'
            });
        });
    });    
})