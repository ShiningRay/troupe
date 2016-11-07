import * as events from '../src/events'
import * as sinon from 'sinon'
import {assert} from 'chai'

describe('EventRouter', function(){
    var router:events.EventRouter = new events.EventRouter();
    
    
    describe('#publish for specific event', function(){
        it('publish events', function(done){
            let ref={node: 'test', id: '1'}
            // let cb = sinon.spy();
            let args = {'nothing': true};
            router.subscribe(ref, 'test', function(a){
                assert.deepEqual(a,args);
                done();
            });
            router.publish(ref, 'test', args);
        });
    });


    describe('#publish for pattern', function(){
        it('publish events', function(done){
            let ref={node: 'test', id: '1'}
            // let cb = sinon.spy();
            let args = {'nothing': true};
            router.subscribe(ref, 'test.*', function(a, name){
                assert.deepEqual(name, 'test.hello');
                assert.deepEqual(a,args);
                done();
            });
            router.publish(ref, 'test.hello', args);
        });
    });
        
})