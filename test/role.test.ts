import {Role} from '../src/role'
import * as sinon from 'sinon'
import {assert} from 'chai'
import * as Promise from 'bluebird';

interface IHello {
    world():PromiseLike<any>;
}
const trait = {
                world(){
                    return Promise.resolve('world')
                }
            }


describe('Role', () => {
    describe('.define', () => {
        it('defines subclass', () => {
            const role = Role.define<IHello>('Hello', trait);
            assert.equal(role, Role.get('Hello'))
        });
    });
});