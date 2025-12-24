import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ImportComponent } from './import/import.component';
import { Routes, RouterModule } from '@angular/router';
import { SearchComponent } from './search/search.component';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { HttpClientModule } from '@angular/common/http';
import { JwtModule, JWT_OPTIONS } from '@auth0/angular-jwt';
import { AuthService } from './auth.service';
import { ReactiveFormsModule } from '@angular/forms';
import { SecurePipe } from './secure.pipe';

const routes: Routes = [
  {path:"import",component:ImportComponent},
  {path:"search",component:SearchComponent}

];


export function jwtOptionsFactory(authService : AuthService) {
  return {
    tokenGetter: () => {
      return authService.getAsyncToken();
    },
    allowedDomains: ["localhost:5001","localhost:5000","coflnet.com"],
    disallowedRoutes: ["http://localhost:5000/auth/gettoken"],
  }
}

@NgModule({
  declarations: [ImportComponent, SearchComponent, SecurePipe],
  imports: [
    RouterModule.forChild(routes),
    CommonModule,
    MatFormFieldModule,
    ReactiveFormsModule,
    MatInputModule,
    MatIconModule,
    MatButtonModule,
    MatAutocompleteModule,
    HttpClientModule,
    JwtModule.forRoot({
      jwtOptionsProvider: {
        provide: JWT_OPTIONS,
        useFactory: jwtOptionsFactory,
        deps: [AuthService]
      }
    }),
  ]
})
export class LifenizerModule { }
