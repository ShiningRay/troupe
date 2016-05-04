import * as core from '../src/core'
import {expect} from 'chai'
import * as sinon from 'sinon'

class DumbActor implements core.IActor {
    public pid: string;
    public messages: any[] = [];
    onstart() {

    }

    onmessage(message: any) {
        this.messages.push(message);
    }

    onerror(error: any) {

    }

    onexit(reason?: any) {

    }

    emit(eventName, ...args: any[]) {

    }

}

describe('core', function () {
    var actor: core.IActor
    describe("#resolve", function () {
        it("should start actor", function () {
            actor = core.start(DumbActor)
            expect(core.resolve(actor.pid)).to.equal(actor);
            var callback = sinon.spy();
            actor.onexit = callback;
            core.stop(actor);
            expect(core.resolve(actor.pid)).to.be.undefined;
            expect(callback.called).to.be.true;
        })
    })

    describe('#send', function () {
        let actor: DumbActor = core.start(DumbActor);
        it("should call messages", function () {
            expect(core.resolve(actor.pid)).to.equal(actor);
            expect(actor.messages).to.be.empty;
            core.send(actor.pid, "message")
            expect(actor.messages).not.to.be.empty;
            expect(actor.messages[0]).to.be.eq("message")
        });
    });
    describe('#toRef', function () {
        it("should convert actor id to ref", function () {
            let ref = core.toRef("test");
            expect(ref.node).not.to.be.undefined;
            expect(ref.id).to.eq('test')

            actor = core.start(DumbActor);
            ref = core.toRef(actor)
            expect(ref.node).not.to.be.undefined;
            expect(ref.id).to.eq(actor.pid);
        });
    });
})